import { execFileSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { request as httpsRequest } from "node:https";
import { mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import process from "node:process";
import piHarnessPolicy from "../pi-harness/extension/index.ts";

const assert = (condition, message) => { if (!condition) throw new Error(message); };
const delay = (ms) => new Promise((done) => setTimeout(done, ms));

function gatewayCall({ port, ca, cert, key, method = "POST", path, body }) {
  return new Promise((resolveCall, rejectCall) => {
    const request = httpsRequest({ hostname: "127.0.0.1", port, method, path, ca, cert, key, minVersion: "TLSv1.3", rejectUnauthorized: true }, (response) => {
      let raw = "";
      response.on("data", (chunk) => { raw += chunk; });
      response.on("end", () => resolveCall({ status: response.statusCode, body: JSON.parse(raw) }));
    });
    request.on("error", rejectCall);
    request.end(body ? JSON.stringify(body) : undefined);
  });
}

const temporary = mkdtempSync(join(tmpdir(), "prueba-memory-gateway."));
const pki = join(temporary, "pki");
const upstreamRequests = [];
const gatewayDatasetId = "11111111-1111-4111-8111-111111111111";
const unrelatedDatasetId = "22222222-2222-4222-8222-222222222222";
let forceGraphFallback = false;
const cognee = createServer(async (request, response) => {
  let raw = "";
  for await (const chunk of request) raw += chunk;
  const isJson = String(request.headers["content-type"] || "").includes("application/json");
  upstreamRequests.push({ path: request.url, key: request.headers["x-api-key"], body: isJson ? JSON.parse(raw || "{}") : raw });
  if (forceGraphFallback && request.url.startsWith("/api/v1/visualize/json?")) {
    response.writeHead(404, { "content-type": "application/json" });
    response.end(JSON.stringify({ detail: "ruta no disponible" }));
    return;
  }
  response.writeHead(200, { "content-type": "application/json" });
  if (request.url === "/api/v1/search") response.end(JSON.stringify([{ content: "contrato encontrado" }]));
  else if (request.url === "/api/v1/datasets") response.end(JSON.stringify([
    { id: gatewayDatasetId, name: "prueba_agentes_internal_engineering_0123456789ab" },
    { id: unrelatedDatasetId, name: "dataset_de_otro_sistema" },
  ]));
  else if (request.url.startsWith("/api/v1/visualize/json?")) response.end(JSON.stringify({
    nodes: [{ id: "empresa", label: "Empresa", type: "Entidad" }, { id: "laravel", label: "Laravel", type: "Tecnología" }],
    links: [{ source: "empresa", target: "laravel", label: "utiliza" }],
  }));
  else if (request.url === `/api/v1/datasets/${gatewayDatasetId}/graph`) response.end(JSON.stringify({
    nodes: [{ id: "fallback", label: "Grafo oficial", type: "Entidad" }], edges: [],
  }));
  else response.end(JSON.stringify({ status: "ok" }));
});

await new Promise((done) => cognee.listen(0, "127.0.0.1", done));
const cogneePort = cognee.address().port;
execFileSync("bash", ["memory-gateway/bin/generar_pki.sh", pki, "127.0.0.1", "backend-test", "frontend-test", "orchestrator-analyst", "memory-admin"], { stdio: "ignore" });
const clientsPath = join(temporary, "clients.json");
writeFileSync(clientsPath, JSON.stringify({ version: 1, clients: {
  "backend-test": { enabled: true, permissions: ["contracts:read", "contracts:write", "business:read", "company:read"], core_ids: ["core-prueba"], tenant_ids: ["empresa-a"] },
  "frontend-test": { enabled: true, permissions: ["contracts:read", "business:read"], core_ids: ["core-prueba"], tenant_ids: ["empresa-a"] },
  "orchestrator-analyst": { enabled: true, permissions: ["contracts:read", "company:read"], core_ids: ["core-prueba"], tenant_ids: [] },
  "memory-admin": { enabled: true, permissions: ["business:write", "company:write", "graphs:read"], core_ids: [], tenant_ids: ["empresa-a"] },
} }));

const gatewayPort = 19443 + Math.floor(Math.random() * 1000);
const gateway = spawn(process.execPath, [resolve("memory-gateway/bin/memory-gateway.mjs")], {
  env: {
    ...process.env,
    MEMORY_GATEWAY_HOST: "127.0.0.1", MEMORY_GATEWAY_PORT: String(gatewayPort),
    MEMORY_GATEWAY_DB: join(temporary, "gateway.sqlite"), MEMORY_GATEWAY_CLIENTS: clientsPath,
    MEMORY_GATEWAY_OPENAPI_DIR: join(temporary, "openapi"),
    MEMORY_GATEWAY_TLS_KEY: join(pki, "server.key"), MEMORY_GATEWAY_TLS_CERT: join(pki, "server.crt"), MEMORY_GATEWAY_TLS_CA: join(pki, "ca.crt"),
    COGNEE_BASE_URL: `http://127.0.0.1:${cogneePort}`,
  },
  stdio: ["ignore", "pipe", "pipe"],
});

const ca = readFileSync(join(pki, "ca.crt"));
const identity = (name) => ({ ca, cert: readFileSync(join(pki, "clients", `${name}.crt`)), key: readFileSync(join(pki, "clients", `${name}.key`)) });

try {
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const health = await gatewayCall({ port: gatewayPort, ...identity("backend-test"), method: "GET", path: "/health" });
      if (health.status === 200 && health.body.semantic_backend === "cognee-oss") { ready = true; break; }
    } catch {}
    await delay(30);
  }
  assert(ready, "el Gateway no inició");

  const endpoint = { method: "POST", path: "/api/users", repository: "usuarios", module: "core", summary: "Crear usuario", response_schema: { type: "object" } };
  const malformedEndpoint = { method: "GET", path: "//api/users/version", repository: "usuarios", module: "core", summary: "Ruta malformada" };
  const malformedPublish = await gatewayCall({ port: gatewayPort, ...identity("backend-test"), path: "/v1/contracts/endpoints", body: { core_id: "core-prueba", endpoint: malformedEndpoint } });
  assert(malformedPublish.status === 400, "el Gateway debía rechazar rutas de contrato con //");

  const published = await gatewayCall({ port: gatewayPort, ...identity("backend-test"), path: "/v1/contracts/endpoints", body: { core_id: "core-prueba", endpoint } });
  assert(published.status === 200 && published.body.endpoint.revision === 1, "backend no publicó el contrato versionado");
  assert(readFileSync(join(temporary, "openapi", "core-prueba", "usuarios.openapi.json"), "utf8").includes("/api/users"), "no se generó OpenAPI canónico");
  assert(upstreamRequests.every((item) => !item.key), "la instalación local de Cognee no debía exigir una clave cloud");
  assert(upstreamRequests.some((item) => item.path === "/api/v1/add"), "el Gateway no agregó la memoria a Cognee");
  assert(upstreamRequests.some((item) => item.path === "/api/v1/cognify"), "el Gateway no ejecutó cognify");
  const contractCognify = upstreamRequests.find((item) => item.path === "/api/v1/cognify" && item.body.graph_model?.title === "Repositorio");
  assert(contractCognify?.body.graph_model?.$defs?.Modulo && contractCognify?.body.graph_model?.$defs?.Endpoint, "Cognee no recibió el modelo Repositorio → Módulo → Endpoint");
  const contractAdd = upstreamRequests.find((item) => item.path === "/api/v1/add" && item.body.includes('contiene_modulos'));
  assert(contractAdd?.body.includes('expone_endpoints') && contractAdd.body.includes('POST /api/users'), "Cognee no recibió el snapshot canónico completo del repositorio");
  const indexedBeforeDuplicate = upstreamRequests.filter((item) => item.path === "/api/v1/add").length;
  const duplicate = await gatewayCall({ port: gatewayPort, ...identity("backend-test"), path: "/v1/contracts/endpoints", body: { core_id: "core-prueba", endpoint } });
  assert(duplicate.body.endpoint.revision === 1 && duplicate.body.changed === false, "una publicación idéntica creó otra revisión");
  assert(upstreamRequests.filter((item) => item.path === "/api/v1/add").length === indexedBeforeDuplicate, "una publicación idéntica se duplicó en Cognee");

  const forbidden = await gatewayCall({ port: gatewayPort, ...identity("frontend-test"), path: "/v1/contracts/endpoints", body: { core_id: "core-prueba", endpoint } });
  assert(forbidden.status === 403, "frontend pudo publicar contratos");
  const crossTenant = await gatewayCall({ port: gatewayPort, ...identity("backend-test"), path: "/v1/memory/search", body: { layer: "business", tenant_id: "empresa-b", query: "reglas" } });
  assert(crossTenant.status === 403, "una VM cruzó el límite de tenant");

  const adminWrite = await gatewayCall({ port: gatewayPort, ...identity("memory-admin"), path: "/v1/admin/memories", body: { layer: "business", tenant_id: "empresa-a", content: "regla privada" } });
  assert(adminWrite.status === 200, "el administrador no pudo registrar memoria privada");
  const technologyWrite = await gatewayCall({ port: gatewayPort, ...identity("memory-admin"), path: "/v1/admin/memories", body: { layer: "company", memory_kind: "repository_technology", repository: "usuarios", technologies: ["PHP 8.4", "Laravel 13"], architecture: "módulo Laravel" } });
  assert(technologyWrite.status === 200, "el administrador no pudo registrar tecnología privada");
  const technologyCognify = upstreamRequests.find((item) => item.path === "/api/v1/cognify" && item.body.graph_model?.$defs?.Tecnologia);
  assert(technologyCognify?.body.custom_prompt?.includes("Repositorio usa Tecnologias"), "Cognee no recibió el modelo Repositorio → Tecnología");
  const analystTechnology = await gatewayCall({ port: gatewayPort, ...identity("orchestrator-analyst"), path: "/v1/memory/search", body: { layer: "company", query: "tecnología del repositorio usuarios" } });
  assert(analystTechnology.status === 200, "el analista no pudo recolectar la tecnología privada");
  const analystCannotWrite = await gatewayCall({ port: gatewayPort, ...identity("orchestrator-analyst"), path: "/v1/admin/memories", body: { layer: "company", content: "no autorizado" } });
  assert(analystCannotWrite.status === 403, "el analista pudo escribir la memoria tecnológica privada");

  const analystCannotListGraphs = await gatewayCall({ port: gatewayPort, ...identity("orchestrator-analyst"), path: "/v1/admin/graphs/datasets", body: {} });
  assert(analystCannotListGraphs.status === 403, "el analista pudo enumerar los grafos administrativos");
  const datasets = await gatewayCall({ port: gatewayPort, ...identity("memory-admin"), path: "/v1/admin/graphs/datasets", body: {} });
  assert(datasets.status === 200 && datasets.body.datasets.length === 1, "el Gateway no filtró sus datasets de Cognee");
  assert(datasets.body.datasets[0].id === gatewayDatasetId, "el Gateway expuso un dataset ajeno");
  const graph = await gatewayCall({ port: gatewayPort, ...identity("memory-admin"), path: "/v1/admin/graphs/view", body: { dataset_id: gatewayDatasetId, max_nodes: 100 } });
  assert(graph.status === 200 && graph.body.graph.nodes.length === 2 && graph.body.graph.links.length === 1, "el administrador no pudo visualizar el grafo");
  forceGraphFallback = true;
  const fallbackGraph = await gatewayCall({ port: gatewayPort, ...identity("memory-admin"), path: "/v1/admin/graphs/view", body: { dataset_id: gatewayDatasetId } });
  forceGraphFallback = false;
  assert(fallbackGraph.status === 200 && fallbackGraph.body.graph.nodes[0].id === "fallback" && fallbackGraph.body.graph.links.length === 0, "falló la compatibilidad con el endpoint oficial de grafo");
  const unrelatedGraph = await gatewayCall({ port: gatewayPort, ...identity("memory-admin"), path: "/v1/admin/graphs/view", body: { dataset_id: unrelatedDatasetId } });
  assert(unrelatedGraph.status === 404, "el Gateway permitió visualizar un dataset ajeno");
  const visualizeRequest = upstreamRequests.find((item) => item.path.startsWith("/api/v1/visualize/json?"));
  assert(visualizeRequest?.path.includes(`dataset_id=${gatewayDatasetId}`), "el Gateway no consultó el endpoint JSON de Cognee");

  const workspace = join(temporary, "workspace"); mkdirSync(workspace);
  const policyPath = join(temporary, "policy.json"); const auditPath = join(temporary, "audit.jsonl");
  writeFileSync(policyPath, JSON.stringify({ version: 1, role: "backend", read: [], write: [], deny_read: [], deny_write: [], memory: { shared_contracts: ["read", "write"], business: ["read"], company: ["read"] } }));
  writeFileSync(auditPath, "");
  Object.assign(process.env, {
    PI_HARNESS_WORKSPACE: workspace, PI_HARNESS_POLICY: policyPath, PI_HARNESS_AUDIT_FILE: auditPath,
    PI_HARNESS_ROLE: "backend", PI_HARNESS_PLATFORM: "linux", PI_HARNESS_SANDBOX_BACKEND: "bwrap", PI_HARNESS_SANDBOX_ENFORCED: "1",
    PI_MEMORY_GATEWAY_URL: `https://127.0.0.1:${gatewayPort}`, PI_MEMORY_CORE_ID: "core-prueba", PI_MEMORY_TENANT_ID: "empresa-a",
    PI_MEMORY_TLS_KEY_FD: String(openSync(join(pki, "clients", "backend-test.key"), "r")),
    PI_MEMORY_TLS_CERT_FD: String(openSync(join(pki, "clients", "backend-test.crt"), "r")),
    PI_MEMORY_TLS_CA_FD: String(openSync(join(pki, "ca.crt"), "r")),
  });
  const tools = new Map();
  piHarnessPolicy({ on() {}, registerTool(definition) { tools.set(definition.name, definition); } });
  assert(tools.has("memoria_buscar") && tools.has("memoria_publicar_endpoint"), "Pi no recibió las herramientas Gateway autorizadas");
  assert(!process.env.PI_MEMORY_TLS_KEY_FD, "la extensión no eliminó los descriptores secretos del entorno");
  const search = await tools.get("memoria_buscar").execute("test", { layer: "shared_contracts", query: "usuarios" });
  assert(search.content[0].text.includes("contrato encontrado"), "Pi no consultó Cognee mediante el Gateway");
  const sharedSearch = upstreamRequests.find((item) => item.path === "/api/v1/search" && item.body.query === "usuarios");
  assert(sharedSearch?.body.datasets?.length === 1 && sharedSearch.body.datasets[0].includes("repository_usuarios"), "la búsqueda no consultó los grafos por repositorio");

  Object.assign(process.env, {
    PI_HARNESS_READ_ONLY: "1",
    PI_MEMORY_GATEWAY_URL: `https://127.0.0.1:${gatewayPort}`,
    PI_MEMORY_TLS_KEY_FD: String(openSync(join(pki, "clients", "backend-test.key"), "r")),
    PI_MEMORY_TLS_CERT_FD: String(openSync(join(pki, "clients", "backend-test.crt"), "r")),
    PI_MEMORY_TLS_CA_FD: String(openSync(join(pki, "ca.crt"), "r")),
  });
  const readOnlyTools = new Map();
  piHarnessPolicy({ on() {}, registerTool(definition) { readOnlyTools.set(definition.name, definition); } });
  assert(readOnlyTools.has("memoria_buscar"), "solo lectura perdió la consulta de memoria");
  assert(!readOnlyTools.has("memoria_publicar_endpoint"), "solo lectura expuso la publicación de contratos");
  delete process.env.PI_HARNESS_READ_ONLY;
} finally {
  gateway.kill("SIGTERM"); cognee.close(); rmSync(temporary, { recursive: true, force: true });
}

console.log("OK: mTLS, RBAC, analista de solo lectura, tenants, SQLite/OpenAPI, auditoría y visualización Cognee OSS verificados.");
