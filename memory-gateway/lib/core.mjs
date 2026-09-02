import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { CogneeClient } from "./cognee.mjs";

const IDENTIFIER = /^[A-Za-z0-9._:-]{1,100}$/;
const DATASET_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const METHODS = new Set(["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"]);

export class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

function identifier(value, name) {
  const normalized = String(value || "");
  if (!IDENTIFIER.test(normalized)) throw new HttpError(400, `${name} no válido`);
  return normalized;
}

function limited(value, max) { return String(value || "").slice(0, max); }

function parseSchema(value) {
  if (!value) return undefined;
  if (typeof value === "object" && !Array.isArray(value)) return value;
  try { return JSON.parse(String(value)); } catch { return { type: "object", description: String(value).slice(0, 4000) }; }
}

export function validateEndpoint(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new HttpError(400, "endpoint debe ser un objeto");
  const method = String(input.method || "").toUpperCase();
  const path = String(input.path || "");
  if (!METHODS.has(method)) throw new HttpError(400, "método HTTP no válido");
  if (!/^\/[A-Za-z0-9_./{}:-]*$/.test(path) || path.includes("..")) throw new HttpError(400, "ruta de endpoint no válida");
  return {
    method,
    path,
    repository: identifier(input.repository, "repository"),
    module: identifier(input.module, "module"),
    summary: limited(input.summary, 1000),
    authentication: limited(input.authentication, 1000),
    request_schema: parseSchema(input.request_schema),
    response_schema: parseSchema(input.response_schema),
    api_version: limited(input.version || "1.0.0", 100),
    source_commit: limited(input.source_commit, 100),
  };
}

export class MemoryGatewayCore {
  constructor({ databasePath, clientsPath, openapiDir, cogneeBaseUrl = "", cogneeApiKey = "", cogneeBearerToken = "", cogneeSearchType = "CHUNKS", cogneeAddTimeoutMs = 60_000, cogneeCognifyTimeoutMs = 600_000, cogneeSearchTimeoutMs = 300_000, cogneeVisualizationTimeoutMs = 60_000, fetchImpl = fetch }) {
    mkdirSync(dirname(databasePath), { recursive: true });
    mkdirSync(openapiDir, { recursive: true });
    this.db = new DatabaseSync(databasePath, { timeout: 5000 });
    this.db.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;");
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS contracts (
        core_id TEXT NOT NULL, repository TEXT NOT NULL, module TEXT NOT NULL,
        method TEXT NOT NULL, path TEXT NOT NULL, document TEXT NOT NULL,
        revision INTEGER NOT NULL, updated_by TEXT NOT NULL, updated_at TEXT NOT NULL,
        PRIMARY KEY(core_id, repository, method, path)
      );
      CREATE TABLE IF NOT EXISTS outbox (
        id TEXT PRIMARY KEY, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
        content TEXT NOT NULL, metadata TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT, created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS private_memories (
        id TEXT PRIMARY KEY, layer TEXT NOT NULL, tenant_id TEXT,
        content TEXT NOT NULL, created_by TEXT NOT NULL, created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS audit (
        id TEXT PRIMARY KEY, timestamp TEXT NOT NULL, identity TEXT NOT NULL,
        operation TEXT NOT NULL, resource TEXT NOT NULL, allowed INTEGER NOT NULL,
        status INTEGER NOT NULL, request_id TEXT NOT NULL, detail TEXT
      );
    `);
    this.clientsPath = clientsPath;
    this.openapiDir = openapiDir;
    this.cognee = new CogneeClient({
      baseUrl: cogneeBaseUrl, apiKey: cogneeApiKey, bearerToken: cogneeBearerToken,
      searchType: cogneeSearchType, addTimeoutMs: cogneeAddTimeoutMs,
      cognifyTimeoutMs: cogneeCognifyTimeoutMs, searchTimeoutMs: cogneeSearchTimeoutMs,
      visualizationTimeoutMs: cogneeVisualizationTimeoutMs,
      fetchImpl,
    });
    this.flushing = false;
  }

  clients() {
    const config = JSON.parse(readFileSync(this.clientsPath, "utf8"));
    if (config.version !== 1 || !config.clients || typeof config.clients !== "object") throw new Error("configuración de clientes inválida");
    return config.clients;
  }

  client(identity) {
    const client = this.clients()[identity];
    if (!client || client.enabled !== true) throw new HttpError(403, "identidad no registrada o deshabilitada");
    return client;
  }

  authorize(identity, permission, { coreId = "", tenantId = "" } = {}) {
    const client = this.client(identity);
    if (!Array.isArray(client.permissions) || !client.permissions.includes(permission)) throw new HttpError(403, `falta el permiso ${permission}`);
    if (coreId && !(client.core_ids || []).includes(coreId)) throw new HttpError(403, `acceso denegado al core ${coreId}`);
    if (tenantId && !(client.tenant_ids || []).includes(tenantId)) throw new HttpError(403, `acceso denegado al tenant ${tenantId}`);
    return client;
  }

  audit({ identity, operation, resource, allowed, status, requestId, detail = "" }) {
    this.db.prepare("INSERT INTO audit VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)").run(
      randomUUID(), new Date().toISOString(), identity, operation, resource, allowed ? 1 : 0, status, requestId, limited(detail, 4000),
    );
  }

  publishEndpoint(identity, body) {
    const coreId = identifier(body.core_id, "core_id");
    this.authorize(identity, "contracts:write", { coreId });
    const endpoint = validateEndpoint(body.endpoint);
    const existing = this.db.prepare(
      "SELECT revision,document FROM contracts WHERE core_id=? AND repository=? AND method=? AND path=?",
    ).get(coreId, endpoint.repository, endpoint.method, endpoint.path);
    if (existing) {
      const previous = JSON.parse(existing.document);
      const previousComparable = { ...previous }; delete previousComparable.revision;
      const nextComparable = { ...endpoint, core_id: coreId };
      if (JSON.stringify(previousComparable) === JSON.stringify(nextComparable)) {
        return { endpoint: previous, openapi: this.openapiPath(coreId, endpoint.repository), changed: false };
      }
    }
    const revision = Number(existing?.revision || 0) + 1;
    const document = { ...endpoint, core_id: coreId, revision };
    const now = new Date().toISOString();
    this.db.prepare(`
      INSERT INTO contracts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(core_id,repository,method,path) DO UPDATE SET
        module=excluded.module, document=excluded.document, revision=excluded.revision,
        updated_by=excluded.updated_by, updated_at=excluded.updated_at
    `).run(coreId, endpoint.repository, endpoint.module, endpoint.method, endpoint.path, JSON.stringify(document), revision, identity, now);
    this.db.prepare("INSERT INTO outbox(id,entity_type,entity_id,content,metadata,created_at) VALUES(?,?,?,?,?,?)").run(
      randomUUID(), "agent_id", `core:${coreId}:contracts`,
      `CONTRATO_ENDPOINT_JSON\n${JSON.stringify(document)}`,
      JSON.stringify({ layer: "shared_contracts", kind: "endpoint", ...document }), now,
    );
    this.writeOpenApi(coreId, endpoint.repository);
    return { endpoint: document, openapi: this.openapiPath(coreId, endpoint.repository), changed: true };
  }

  openapiPath(coreId, repository) { return join(this.openapiDir, coreId, `${repository}.openapi.json`); }

  writeOpenApi(coreId, repository) {
    const rows = this.db.prepare("SELECT document FROM contracts WHERE core_id=? AND repository=? ORDER BY path, method, module").all(coreId, repository);
    const paths = {};
    for (const row of rows) {
      const endpoint = JSON.parse(row.document);
      const operation = {
        summary: endpoint.summary,
        operationId: `${endpoint.module}_${endpoint.method.toLowerCase()}_${createHash("sha256").update(endpoint.path).digest("hex").slice(0, 12)}`,
        "x-module": endpoint.module,
        "x-source-commit": endpoint.source_commit,
        responses: { "200": { description: "Respuesta exitosa", ...(endpoint.response_schema ? { content: { "application/json": { schema: endpoint.response_schema } } } : {}) } },
      };
      if (endpoint.request_schema) operation.requestBody = { content: { "application/json": { schema: endpoint.request_schema } } };
      if (endpoint.authentication) operation.security = [{ bearerAuth: [] }];
      paths[endpoint.path] ||= {};
      paths[endpoint.path][endpoint.method.toLowerCase()] = operation;
    }
    const spec = {
      openapi: "3.1.0",
      info: { title: `${repository} API`, version: "1.0.0", "x-core-id": coreId },
      paths,
      components: { securitySchemes: { bearerAuth: { type: "http", scheme: "bearer" } } },
    };
    const target = this.openapiPath(coreId, repository);
    mkdirSync(dirname(target), { recursive: true });
    const temporary = `${target}.${process.pid}.tmp`;
    writeFileSync(temporary, `${JSON.stringify(spec, null, 2)}\n`, { mode: 0o640 });
    renameSync(temporary, target);
  }

  async flushOutbox(limit = 50) {
    if (!this.cognee.configured) return { indexed: 0, pending: this.pendingOutbox() };
    if (this.flushing) return { indexed: 0, pending: this.pendingOutbox(), busy: true };
    this.flushing = true;
    let indexed = 0;
    try {
      const rows = this.db.prepare("SELECT * FROM outbox ORDER BY created_at LIMIT ?").all(limit);
      for (const row of rows) {
        try {
          await this.cognee.index({
            id: row.id, entityId: row.entity_id, content: row.content, metadata: JSON.parse(row.metadata),
          });
          this.db.prepare("DELETE FROM outbox WHERE id=?").run(row.id);
          indexed += 1;
        } catch (error) {
          this.db.prepare("UPDATE outbox SET attempts=attempts+1,last_error=? WHERE id=?").run(limited(error.message, 2000), row.id);
        }
      }
      return { indexed, pending: this.pendingOutbox() };
    } finally {
      this.flushing = false;
    }
  }

  pendingOutbox() { return Number(this.db.prepare("SELECT COUNT(*) AS total FROM outbox").get().total); }

  async search(identity, body) {
    const layer = String(body.layer || "");
    const query = limited(body.query, 4000).trim();
    if (!query) throw new HttpError(400, "query es obligatorio");
    let entityId;
    if (layer === "shared_contracts") {
      const coreId = identifier(body.core_id, "core_id");
      this.authorize(identity, "contracts:read", { coreId });
      entityId = `core:${coreId}:contracts`;
    } else if (layer === "business") {
      const tenantId = identifier(body.tenant_id, "tenant_id");
      this.authorize(identity, "business:read", { tenantId });
      entityId = `business:${tenantId}`;
    } else if (layer === "company") {
      this.authorize(identity, "company:read");
      entityId = "internal:engineering";
    } else throw new HttpError(400, "capa de memoria no válida");
    if (this.cognee.configured) {
      try {
        const result = await this.cognee.search({ entityId, query });
        return { layer, dataset: result.dataset, result: result.result };
      } catch {
        // Fallback a SQLite si Cognee no responde
      }
    }
    if (layer === "shared_contracts") {
      const coreId = identifier(body.core_id, "core_id");
      const rows = this.db.prepare("SELECT document FROM contracts WHERE core_id=?").all(coreId);
      const result = rows.map((r) => JSON.parse(r.document));
      return { layer, dataset: `sqlite_${coreId}`, result };
    } else if (layer === "company") {
      const rows = this.db.prepare("SELECT content FROM private_memories WHERE layer='company'").all();
      return { layer, dataset: "sqlite_company", result: rows.map((r) => r.content) };
    }
    return { layer, dataset: "sqlite_fallback", result: [] };
  }

  writePrivateMemory(identity, body) {
    const layer = String(body.layer || "");
    const content = limited(body.content, 12000).trim();
    if (!content) throw new HttpError(400, "content es obligatorio");
    let entityType;
    let entityId;
    let tenantId = null;
    if (layer === "business") {
      tenantId = identifier(body.tenant_id, "tenant_id");
      this.authorize(identity, "business:write", { tenantId });
      entityType = "user_id";
      entityId = `business:${tenantId}`;
    } else if (layer === "company") {
      this.authorize(identity, "company:write");
      entityType = "agent_id";
      entityId = "internal:engineering";
    } else throw new HttpError(400, "sólo se administran las capas business y company");
    const id = randomUUID();
    const now = new Date().toISOString();
    this.db.prepare("INSERT INTO private_memories VALUES(?,?,?,?,?,?)").run(id, layer, tenantId, content, identity, now);
    this.db.prepare("INSERT INTO outbox(id,entity_type,entity_id,content,metadata,created_at) VALUES(?,?,?,?,?,?)").run(
      randomUUID(), entityType, entityId, `${layer === "business" ? "CAPA_NEGOCIO" : "CAPA_EMPRESA"}: ${content}`,
      JSON.stringify({ layer, gateway_memory_id: id }), now,
    );
    return { id, layer, tenant_id: tenantId, created_at: now };
  }

  async listGraphs(identity) {
    this.authorize(identity, "graphs:read");
    if (!this.cognee.configured) throw new HttpError(503, "Cognee no está configurado");
    const datasets = await this.cognee.datasets();
    return datasets
      .map((dataset) => ({
        id: String(dataset.id || dataset.dataset_id || ""),
        name: String(dataset.name || dataset.dataset_name || ""),
        created_at: dataset.created_at || dataset.createdAt || null,
        updated_at: dataset.updated_at || dataset.updatedAt || null,
      }))
      .filter((dataset) => DATASET_ID.test(dataset.id) && dataset.name.startsWith("prueba_agentes_"))
      .sort((left, right) => left.name.localeCompare(right.name));
  }

  async visualizeGraph(identity, body) {
    const datasetId = String(body.dataset_id || "");
    if (!DATASET_ID.test(datasetId)) throw new HttpError(400, "dataset_id no válido");
    const datasets = await this.listGraphs(identity);
    const dataset = datasets.find((candidate) => candidate.id.toLowerCase() === datasetId.toLowerCase());
    if (!dataset) throw new HttpError(404, "dataset no encontrado o fuera del ámbito del Gateway");
    const query = limited(body.query, 1000).trim();
    const neighborhoodDepth = Math.min(6, Math.max(1, Number(body.neighborhood_depth) || 2));
    const maxNodes = Math.min(1000, Math.max(10, Number(body.max_nodes) || 250));
    const graph = await this.cognee.visualize({
      datasetId: dataset.id,
      full: body.full === true,
      query,
      neighborhoodDepth,
      maxNodes,
    });
    return { dataset, graph };
  }

  close() { this.db.close(); }
}
