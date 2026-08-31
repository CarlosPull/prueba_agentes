#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:https";
import { randomUUID } from "node:crypto";
import { MemoryGatewayCore, HttpError } from "../lib/core.mjs";

const required = (name) => process.env[name] || (() => { throw new Error(`falta ${name}`); })();
const optionalSecret = (name, fileName) => process.env[name]
  || (process.env[fileName] && existsSync(process.env[fileName]) ? readFileSync(process.env[fileName], "utf8").trim() : "");
const host = process.env.MEMORY_GATEWAY_HOST || "0.0.0.0";
const port = Number(process.env.MEMORY_GATEWAY_PORT || 9443);
const core = new MemoryGatewayCore({
  databasePath: required("MEMORY_GATEWAY_DB"),
  clientsPath: required("MEMORY_GATEWAY_CLIENTS"),
  openapiDir: required("MEMORY_GATEWAY_OPENAPI_DIR"),
  cogneeBaseUrl: required("COGNEE_BASE_URL"),
  cogneeApiKey: optionalSecret("COGNEE_API_KEY", "COGNEE_API_KEY_FILE"),
  cogneeBearerToken: optionalSecret("COGNEE_BEARER_TOKEN", "COGNEE_BEARER_TOKEN_FILE"),
  cogneeSearchType: process.env.COGNEE_SEARCH_TYPE || "CHUNKS",
  cogneeAddTimeoutMs: Number(process.env.COGNEE_ADD_TIMEOUT_MS || 60_000),
  cogneeCognifyTimeoutMs: Number(process.env.COGNEE_COGNIFY_TIMEOUT_MS || 600_000),
  cogneeSearchTimeoutMs: Number(process.env.COGNEE_SEARCH_TIMEOUT_MS || 300_000),
});

function send(response, status, body, requestId) {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8", "x-request-id": requestId });
  response.end(`${JSON.stringify(body)}\n`);
}

async function body(request) {
  let raw = "";
  for await (const chunk of request) {
    raw += chunk;
    if (Buffer.byteLength(raw) > 64 * 1024) throw new HttpError(413, "solicitud demasiado grande");
  }
  return JSON.parse(raw || "{}");
}

const server = createServer({
  key: readFileSync(required("MEMORY_GATEWAY_TLS_KEY")),
  cert: readFileSync(required("MEMORY_GATEWAY_TLS_CERT")),
  ca: readFileSync(required("MEMORY_GATEWAY_TLS_CA")),
  requestCert: true,
  rejectUnauthorized: true,
  minVersion: "TLSv1.3",
}, async (request, response) => {
  const requestId = request.headers["x-request-id"] || randomUUID();
  const identity = request.socket.getPeerCertificate()?.subject?.CN || "sin-identidad";
  let operation = `${request.method} ${request.url}`;
  try {
    if (!request.socket.authorized) throw new HttpError(401, "certificado de cliente no autorizado");
    if (request.method === "GET" && request.url === "/health") {
      core.client(identity);
      return send(response, 200, { status: "ok", identity, semantic_backend: "cognee-oss", outbox_pending: core.pendingOutbox() }, requestId);
    }
    if (request.method !== "POST") throw new HttpError(405, "método no permitido");
    const payload = await body(request);
    if (request.url === "/v1/contracts/endpoints") {
      const result = core.publishEndpoint(identity, payload);
      const indexing = await core.flushOutbox(1);
      core.audit({ identity, operation, resource: `core:${payload.core_id}`, allowed: true, status: 200, requestId });
      return send(response, 200, { ...result, indexing }, requestId);
    }
    if (request.url === "/v1/memory/search") {
      const result = await core.search(identity, payload);
      core.audit({ identity, operation, resource: payload.layer, allowed: true, status: 200, requestId });
      return send(response, 200, result, requestId);
    }
    if (request.url === "/v1/admin/memories") {
      const result = core.writePrivateMemory(identity, payload);
      const indexing = await core.flushOutbox(1);
      core.audit({ identity, operation, resource: payload.layer, allowed: true, status: 200, requestId });
      return send(response, 200, { ...result, indexing }, requestId);
    }
    throw new HttpError(404, "ruta no encontrada");
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    try { core.audit({ identity, operation, resource: request.url || "", allowed: false, status, requestId, detail: error.message }); } catch {}
    return send(response, status, { error: status === 500 ? "error interno" : error.message }, requestId);
  }
});

server.listen(port, host, () => process.stdout.write(`Memory Gateway escuchando en https://${host}:${port}\n`));
const retryTimer = setInterval(async () => {
  await core.flushOutbox(5);
}, 30_000);
retryTimer.unref();
const shutdown = () => server.close(() => { clearInterval(retryTimer); core.close(); process.exit(0); });
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
