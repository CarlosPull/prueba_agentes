import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { CogneeClient } from "./cognee.mjs";

const IDENTIFIER = /^[A-Za-z0-9._:-]{1,100}$/;
const DATASET_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const METHODS = new Set(["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"]);

export const CONTRACT_GRAPH_MODEL = {
  title: "Repositorio",
  type: "object",
  properties: {
    name: { type: "string", description: "Identificador único del repositorio" },
    contiene_modulos: { type: "array", items: { $ref: "#/$defs/Modulo" } },
  },
  required: ["name", "contiene_modulos"],
  $defs: {
    Modulo: {
      title: "Modulo", type: "object",
      properties: {
        name: { type: "string" },
        expone_endpoints: { type: "array", items: { $ref: "#/$defs/Endpoint" } },
      },
      required: ["name", "expone_endpoints"],
    },
    Endpoint: {
      title: "Endpoint", type: "object",
      properties: {
        name: { type: "string", description: "Método y ruta; identidad estable del endpoint" },
        metodo: { type: "string" }, ruta: { type: "string" }, resumen: { type: "string" },
        autenticacion: { type: "string" }, version_api: { type: "string" }, commit_fuente: { type: "string" },
      },
      required: ["name", "metodo", "ruta"],
    },
  },
};

export const TECHNOLOGY_GRAPH_MODEL = {
  title: "Repositorio",
  type: "object",
  properties: {
    name: { type: "string", description: "Identificador único del repositorio" },
    arquitectura: { type: "string" },
    usa_tecnologias: { type: "array", items: { $ref: "#/$defs/Tecnologia" } },
  },
  required: ["name", "usa_tecnologias"],
  $defs: {
    Tecnologia: {
      title: "Tecnologia", type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
    },
  },
};

const CONTRACT_GRAPH_PROMPT = "Construye exclusivamente la jerarquía indicada por el JSON: un Repositorio contiene Modulos y cada Modulo expone Endpoints. Conserva método, ruta y propiedades del endpoint; no inventes entidades ni relaciones.";
const TECHNOLOGY_GRAPH_PROMPT = "Construye exclusivamente la jerarquía indicada por el JSON: un Repositorio usa Tecnologias. Conserva la arquitectura como propiedad; no inventes tecnologías, entidades ni relaciones.";

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
  if (!/^\/[A-Za-z0-9_./{}:-]*$/.test(path) || path.includes("..") || path.includes("//")) throw new HttpError(400, "ruta de endpoint no válida");
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
        content TEXT NOT NULL, created_by TEXT NOT NULL, created_at TEXT NOT NULL,
        repository TEXT
      );
      CREATE TABLE IF NOT EXISTS audit (
        id TEXT PRIMARY KEY, timestamp TEXT NOT NULL, identity TEXT NOT NULL,
        operation TEXT NOT NULL, resource TEXT NOT NULL, allowed INTEGER NOT NULL,
        status INTEGER NOT NULL, request_id TEXT NOT NULL, detail TEXT
      );
    `);
    const privateColumns = this.db.prepare("PRAGMA table_info(private_memories)").all().map((column) => column.name);
    if (!privateColumns.includes("repository")) this.db.exec("ALTER TABLE private_memories ADD COLUMN repository TEXT");
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
    this.enqueueContractRepository(coreId, endpoint.repository, now);
    this.writeOpenApi(coreId, endpoint.repository);
    return { endpoint: document, openapi: this.openapiPath(coreId, endpoint.repository), changed: true };
  }

  contractEntityId(coreId, repository) { return `v2:contracts:repository:${repository}:core:${coreId}`; }

  companyRepositoryEntityId(repository) { return `v2:company:repository:${repository}`; }

  repositoryContractDocument(coreId, repository) {
    const rows = this.db.prepare("SELECT document FROM contracts WHERE core_id=? AND repository=? ORDER BY module,path,method").all(coreId, repository);
    const modules = new Map();
    for (const row of rows) {
      const endpoint = JSON.parse(row.document);
      if (!modules.has(endpoint.module)) modules.set(endpoint.module, []);
      modules.get(endpoint.module).push({
        name: `${endpoint.method} ${endpoint.path}`,
        metodo: endpoint.method,
        ruta: endpoint.path,
        resumen: endpoint.summary || "",
        autenticacion: endpoint.authentication || "",
        version_api: endpoint.api_version || "",
        commit_fuente: endpoint.source_commit || "",
      });
    }
    return {
      repositorio: repository,
      nombre_del_repositorio: repository,
      name: repository,
      contiene_modulos: [...modules.entries()].map(([name, expone_endpoints]) => ({ name, expone_endpoints })),
    };
  }

  enqueueSnapshot({ entityId, content, metadata, now = new Date().toISOString() }) {
    this.db.prepare("DELETE FROM outbox WHERE entity_id=?").run(entityId);
    this.db.prepare("INSERT INTO outbox(id,entity_type,entity_id,content,metadata,created_at) VALUES(?,?,?,?,?,?)").run(
      randomUUID(), "agent_id", entityId, JSON.stringify(content), JSON.stringify(metadata), now,
    );
  }

  enqueueContractRepository(coreId, repository, now = new Date().toISOString()) {
    const entityId = this.contractEntityId(coreId, repository);
    this.enqueueSnapshot({
      entityId,
      content: this.repositoryContractDocument(coreId, repository),
      metadata: { layer: "shared_contracts", kind: "repository_contracts_v2", core_id: coreId, repository, graph_model: "repository_contracts_v2", replace_dataset: true },
      now,
    });
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
            graphModel: JSON.parse(row.metadata).graph_model === "repository_contracts_v2" ? CONTRACT_GRAPH_MODEL
              : JSON.parse(row.metadata).graph_model === "repository_technologies_v2" ? TECHNOLOGY_GRAPH_MODEL : undefined,
            customPrompt: JSON.parse(row.metadata).graph_model === "repository_contracts_v2" ? CONTRACT_GRAPH_PROMPT
              : JSON.parse(row.metadata).graph_model === "repository_technologies_v2" ? TECHNOLOGY_GRAPH_PROMPT : "",
            replaceDataset: JSON.parse(row.metadata).replace_dataset === true,
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
    let entityIds;
    if (layer === "shared_contracts") {
      const coreId = identifier(body.core_id, "core_id");
      this.authorize(identity, "contracts:read", { coreId });
      entityIds = this.db.prepare("SELECT DISTINCT repository FROM contracts WHERE core_id=? ORDER BY repository").all(coreId)
        .map((row) => this.contractEntityId(coreId, row.repository));
    } else if (layer === "business") {
      const tenantId = identifier(body.tenant_id, "tenant_id");
      this.authorize(identity, "business:read", { tenantId });
      entityIds = [`business:${tenantId}`];
    } else if (layer === "company") {
      this.authorize(identity, "company:read");
      const repositories = this.db.prepare("SELECT DISTINCT repository FROM private_memories WHERE layer='company' AND repository IS NOT NULL ORDER BY repository").all();
      entityIds = ["v2:company:general", ...repositories.map((row) => this.companyRepositoryEntityId(row.repository))];
    } else throw new HttpError(400, "capa de memoria no válida");
    if (this.cognee.configured) {
      try {
        const result = await this.cognee.search({ entityIds, query });
        return { layer, dataset: result.dataset, datasets: result.datasets, result: result.result };
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
    if (layer === "company" && body.memory_kind === "repository_technology") return this.writeRepositoryTechnology(identity, body);
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
      entityId = "v2:company:general";
    } else throw new HttpError(400, "sólo se administran las capas business y company");
    const id = randomUUID();
    const now = new Date().toISOString();
    this.db.prepare("INSERT INTO private_memories(id,layer,tenant_id,content,created_by,created_at,repository) VALUES(?,?,?,?,?,?,NULL)").run(id, layer, tenantId, content, identity, now);
    this.db.prepare("INSERT INTO outbox(id,entity_type,entity_id,content,metadata,created_at) VALUES(?,?,?,?,?,?)").run(
      randomUUID(), entityType, entityId, `${layer === "business" ? "CAPA_NEGOCIO" : "CAPA_EMPRESA"}: ${content}`,
      JSON.stringify({ layer, gateway_memory_id: id }), now,
    );
    return { id, layer, tenant_id: tenantId, created_at: now };
  }

  writeRepositoryTechnology(identity, body) {
    this.authorize(identity, "company:write");
    const repository = identifier(body.repository, "repository");
    const technologies = Array.isArray(body.technologies)
      ? [...new Set(body.technologies.map((item) => limited(item, 200).trim()).filter(Boolean))].slice(0, 100)
      : null;
    if (!technologies) throw new HttpError(400, "technologies debe ser un arreglo");
    const architecture = limited(body.architecture, 1000).trim();
    const document = { name: repository, arquitectura: architecture, usa_tecnologias: technologies.map((name) => ({ name })) };
    const id = randomUUID();
    const now = new Date().toISOString();
    this.db.prepare("DELETE FROM private_memories WHERE layer='company' AND repository=?").run(repository);
    this.db.prepare("INSERT INTO private_memories(id,layer,tenant_id,content,created_by,created_at,repository) VALUES(?,'company',NULL,?,?,?,?)").run(
      id, JSON.stringify(document), identity, now, repository,
    );
    this.enqueueSnapshot({
      entityId: this.companyRepositoryEntityId(repository),
      content: document,
      metadata: { layer: "company", kind: "repository_technologies_v2", repository, graph_model: "repository_technologies_v2", replace_dataset: true },
      now,
    });
    return { id, layer: "company", repository, created_at: now };
  }

  prepareCanonicalRebuild(technologies = {}) {
    const repairedContracts = this.repairMalformedContractPaths();
    this.db.exec("DELETE FROM outbox");
    const contracts = this.db.prepare("SELECT DISTINCT core_id,repository FROM contracts ORDER BY core_id,repository").all();
    for (const row of contracts) this.enqueueContractRepository(row.core_id, row.repository);
    for (const [repository, technology] of Object.entries(technologies)) {
      const normalizedRepository = identifier(repository, "repository");
      const list = Array.isArray(technology?.technologies) ? technology.technologies : [];
      const document = {
        name: normalizedRepository,
        arquitectura: limited(technology?.architecture, 1000),
        usa_tecnologias: [...new Set(list.map((item) => limited(item, 200).trim()).filter(Boolean))].map((name) => ({ name })),
      };
      const id = randomUUID();
      const now = new Date().toISOString();
      this.db.prepare("DELETE FROM private_memories WHERE layer='company' AND repository=?").run(normalizedRepository);
      this.db.prepare("INSERT INTO private_memories(id,layer,tenant_id,content,created_by,created_at,repository) VALUES(?,'company',NULL,?,'canonical-rebuild',?,?)").run(
        id, JSON.stringify(document), now, normalizedRepository,
      );
      this.enqueueSnapshot({
        entityId: this.companyRepositoryEntityId(normalizedRepository), content: document,
        metadata: { layer: "company", kind: "repository_technologies_v2", repository: normalizedRepository, graph_model: "repository_technologies_v2", replace_dataset: true }, now,
      });
    }
    return { contract_repositories: contracts.length, technology_repositories: Object.keys(technologies).length, repaired_contracts: repairedContracts, pending: this.pendingOutbox() };
  }

  repairMalformedContractPaths() {
    const malformed = this.db.prepare("SELECT * FROM contracts WHERE path LIKE '//%' ORDER BY repository,path").all();
    let repaired = 0;
    for (const row of malformed) {
      const normalizedPath = `/${row.path.replace(/^\/+/, "")}`;
      const current = JSON.parse(row.document);
      const existing = this.db.prepare("SELECT document FROM contracts WHERE core_id=? AND repository=? AND method=? AND path=?").get(
        row.core_id, row.repository, row.method, normalizedPath,
      );
      if (existing) {
        const normalizedCurrent = { ...current, path: normalizedPath };
        if (JSON.stringify(normalizedCurrent) !== JSON.stringify(JSON.parse(existing.document))) {
          throw new Error(`contratos en conflicto para ${row.method} ${normalizedPath}`);
        }
        this.db.prepare("DELETE FROM contracts WHERE core_id=? AND repository=? AND method=? AND path=?").run(row.core_id, row.repository, row.method, row.path);
      } else {
        current.path = normalizedPath;
        this.db.prepare("UPDATE contracts SET path=?,document=? WHERE core_id=? AND repository=? AND method=? AND path=?").run(
          normalizedPath, JSON.stringify(current), row.core_id, row.repository, row.method, row.path,
        );
      }
      this.writeOpenApi(row.core_id, row.repository);
      repaired += 1;
    }
    return repaired;
  }

  async cleanupLegacyDatasets() {
    if (!this.cognee.configured) return 0;
    try {
      const datasets = await this.cognee.datasets();
      let deletedCount = 0;
      for (const ds of datasets) {
        const name = String(ds.name || ds.dataset_name || "");
        if (name.startsWith("prueba_agentes_v2_") || (name.startsWith("prueba_agentes_") && !name.startsWith("prueba_agentes_repo_") && !name.startsWith("prueba_agentes_tenant_") && !name.startsWith("prueba_agentes_company_"))) {
          const dsId = String(ds.id || ds.dataset_id || "");
          await this.cognee.deleteDataset(dsId);
          deletedCount += 1;
        }
      }
      return deletedCount;
    } catch (error) {
      process.stderr.write(`[MemoryGateway] Error al limpiar datasets antiguos: ${error.message}\n`);
      return 0;
    }
  }

  async listGraphs(identity) {
    this.authorize(identity, "graphs:read");
    if (!this.cognee.configured) throw new HttpError(503, "Cognee no está configurado");
    let datasets = [];
    try {
      datasets = await this.cognee.datasets();
    } catch (error) {
      process.stderr.write(`[MemoryGateway] No se pudieron obtener datasets de Cognee: ${error.message}\n`);
    }
    const known = new Map();
    for (const row of this.db.prepare("SELECT DISTINCT core_id,repository FROM contracts").all()) {
      known.set(this.cognee.dataset(this.contractEntityId(row.core_id, row.repository), row.repository), { layer: "shared_contracts", core_id: row.core_id, repository: row.repository });
    }
    for (const row of this.db.prepare("SELECT DISTINCT repository FROM private_memories WHERE layer='company' AND repository IS NOT NULL").all()) {
      known.set(this.cognee.dataset(this.companyRepositoryEntityId(row.repository), row.repository), { layer: "company", repository: row.repository });
    }
    return datasets
      .map((dataset) => {
        const name = String(dataset.name || dataset.dataset_name || "");
        let repository = known.get(name)?.repository;
        if (!repository && name.startsWith("prueba_agentes_repo_")) {
          const rawRepo = name.replace(/^prueba_agentes_repo_/, "");
          const matched = this.db.prepare("SELECT DISTINCT repository FROM contracts WHERE replace(repository, '-', '_')=?").get(rawRepo)
            || this.db.prepare("SELECT DISTINCT repository FROM private_memories WHERE replace(repository, '-', '_')=?").get(rawRepo);
          repository = matched ? matched.repository : rawRepo.replace(/_/g, "-");
        }
        return ({
          id: String(dataset.id || dataset.dataset_id || ""),
          name,
          created_at: dataset.created_at || dataset.createdAt || null,
          updated_at: dataset.updated_at || dataset.updatedAt || null,
          repository,
          ...(known.get(name) || {}),
        });
      })
      .filter((dataset) => DATASET_ID.test(dataset.id) && dataset.name.startsWith("prueba_agentes_"))
      .sort((left, right) => left.name.localeCompare(right.name));
  }

  async visualizeGraph(identity, body) {
    const datasetId = String(body.dataset_id || "");
    if (datasetId.toUpperCase() === "ALL_DATASETS") {
      const datasets = await this.listGraphs(identity);
      const query = limited(body.query, 1000).trim();
      const neighborhoodDepth = Math.min(6, Math.max(1, Number(body.neighborhood_depth) || 2));
      const maxNodes = Math.min(1000, Math.max(10, Number(body.max_nodes) || 250));
      const allNodes = new Map();
      const allLinks = new Map();
      for (const dataset of datasets) {
        try {
          let graph = await this.cognee.visualize({
            datasetId: dataset.id,
            full: body.full === true,
            query,
            neighborhoodDepth,
            maxNodes,
          });
          graph = this.unifyGraphNodes(graph);
          if (dataset.repository) graph = this.scopeRepositoryGraph(graph, dataset, body.full === true);
          for (const node of graph.nodes || []) {
            const id = String(node.id ?? node.identifier ?? node.name ?? "");
            if (id && !allNodes.has(id)) allNodes.set(id, node);
          }
          for (const link of graph.links || []) {
            const src = String(link.source?.id ?? link.source ?? "");
            const tgt = String(link.target?.id ?? link.target ?? "");
            const label = String(link.relation || link.label || link.relationship_name || link.edge_info?.relationship_name || "");
            const key = `${src}->${label}->${tgt}`;
            if (src && tgt && !allLinks.has(key)) allLinks.set(key, link);
          }
        } catch {}
      }
      return {
        dataset: { id: "ALL_DATASETS", name: "prueba_agentes_VISTA_GENERAL_GLOBAL" },
        graph: this.unifyGraphNodes({ nodes: Array.from(allNodes.values()), links: Array.from(allLinks.values()) })
      };
    }
    if (!DATASET_ID.test(datasetId)) throw new HttpError(400, "dataset_id no válido");
    const datasets = await this.listGraphs(identity);
    const dataset = datasets.find((candidate) => candidate.id.toLowerCase() === datasetId.toLowerCase());
    if (!dataset) throw new HttpError(404, "dataset no encontrado o fuera del ámbito del Gateway");
    const query = limited(body.query, 1000).trim();
    const neighborhoodDepth = Math.min(6, Math.max(1, Number(body.neighborhood_depth) || 2));
    const maxNodes = Math.min(1000, Math.max(10, Number(body.max_nodes) || 250));

    const targetRepo = dataset.repository;
    const repoDatasets = targetRepo
      ? datasets.filter((candidate) => candidate.repository === targetRepo)
      : [dataset];

    const mergedNodes = new Map();
    const mergedLinks = new Map();

    for (const item of repoDatasets) {
      try {
        let g = await this.cognee.visualize({
          datasetId: item.id,
          full: body.full === true,
          query,
          neighborhoodDepth,
          maxNodes,
        });
        g = this.unifyGraphNodes(g, targetRepo);
        if (item.repository) g = this.scopeRepositoryGraph(g, item, body.full === true);
        for (const node of g.nodes || []) {
          const id = String(node.id ?? node.identifier ?? node.name ?? "");
          if (id && !mergedNodes.has(id)) mergedNodes.set(id, node);
        }
        for (const link of g.links || []) {
          const src = String(link.source?.id ?? link.source ?? "");
          const tgt = String(link.target?.id ?? link.target ?? "");
          const label = String(link.relation || link.label || link.relationship_name || link.edge_info?.relationship_name || "");
          const key = `${src}->${label}->${tgt}`;
          if (src && tgt && !mergedLinks.has(key)) mergedLinks.set(key, link);
        }
      } catch {}
    }

    const unifiedFinal = this.unifyGraphNodes(
      { nodes: Array.from(mergedNodes.values()), links: Array.from(mergedLinks.values()) },
      targetRepo
    );
    const scopedFinal = dataset.repository
      ? this.scopeRepositoryGraph(unifiedFinal, dataset, body.full === true)
      : unifiedFinal;

    return {
      dataset,
      graph: scopedFinal,
    };
  }

  unifyGraphNodes(graph, targetRepository = null) {
    if (!graph || !Array.isArray(graph.nodes) || !graph.nodes.length) return graph || { nodes: [], links: [] };
    const nodeId = (value) => String(value?.id ?? value?.identifier ?? value ?? "");
    const nodeMapping = new Map();
    const canonicalNodes = new Map();
    const moduleToRepo = new Map();
    const repoTechs = new Map();

    try {
      const query = targetRepository
        ? this.db.prepare("SELECT DISTINCT module, repository FROM contracts WHERE repository=?").all(targetRepository)
        : this.db.prepare("SELECT DISTINCT module, repository FROM contracts").all();
      for (const row of query) {
        moduleToRepo.set(row.module, row.repository);
      }
    } catch {}

    try {
      const techRows = targetRepository
        ? this.db.prepare("SELECT repository, content FROM private_memories WHERE layer='company' AND repository=?").all(targetRepository)
        : this.db.prepare("SELECT repository, content FROM private_memories WHERE layer='company' AND repository IS NOT NULL").all();
      for (const row of techRows) {
        if (!row.repository || row.repository === "version" || row.repository === "repositories") continue;
        try {
          const doc = JSON.parse(row.content);
          if (Array.isArray(doc.usa_tecnologias)) {
            const list = doc.usa_tecnologias.map((t) => String(t.name || t).trim()).filter(Boolean);
            if (list.length) repoTechs.set(row.repository, list);
          }
        } catch {}
      }
    } catch {}

    for (const node of graph.nodes) {
      const origId = nodeId(node);
      const nodeType = String(node.type || node.node_type || node.kind || "");
      const nodeName = String(node.name || node.nombre || node.label || node.title || origId);

      let canonicalId = origId;
      const typeLower = nodeType.toLowerCase();
      const cleanName = nodeName.trim();
      if ((typeLower === "repositorio" || typeLower === "repository") && cleanName) {
        canonicalId = `repo:${cleanName}`;
      } else if ((typeLower === "modulo" || typeLower === "module") && cleanName) {
        canonicalId = `module:${cleanName}`;
      } else if (typeLower === "endpoint" && cleanName) {
        canonicalId = `endpoint:${cleanName}`;
      } else if ((typeLower === "tecnologia" || typeLower === "technology") && cleanName) {
        canonicalId = `tech:${cleanName}`;
      }

      nodeMapping.set(origId, canonicalId);
      if (!canonicalNodes.has(canonicalId)) {
        canonicalNodes.set(canonicalId, { ...node, id: canonicalId, label: node.label || cleanName, name: cleanName });
      }
    }

    const canonicalLinks = new Map();
    for (const link of graph.links || graph.edges || []) {
      const origSrc = nodeId(link.source);
      const origTgt = nodeId(link.target);
      let src = nodeMapping.get(origSrc) || origSrc;
      const tgt = nodeMapping.get(origTgt) || origTgt;
      const label = String(link.relation || link.label || link.relationship_name || link.edge_info?.relationship_name || "");

      if (label === "usa_tecnologias" && (src.includes("Repositorio") || src.includes("repositories") || src.includes("version"))) {
        continue;
      }

      if (label === "contiene_modulos") {
        const tgtNode = canonicalNodes.get(tgt) || graph.nodes.find((n) => nodeId(n) === origTgt);
        const tgtModuleName = String(tgtNode?.name || tgtNode?.nombre || tgtNode?.label || "");
        if (tgtModuleName && moduleToRepo.has(tgtModuleName)) {
          const expectedRepo = moduleToRepo.get(tgtModuleName);
          const repoId = `repo:${expectedRepo}`;
          if (!canonicalNodes.has(repoId)) {
            canonicalNodes.set(repoId, { id: repoId, name: expectedRepo, label: expectedRepo, type: "Repositorio" });
          }
          src = repoId;
        }
      }

      const key = `${src}->${label}->${tgt}`;
      if (src && tgt && !canonicalLinks.has(key)) {
        canonicalLinks.set(key, { ...link, source: src, target: tgt, label });
      }
    }

    for (const [repoName, techs] of repoTechs.entries()) {
      const repoId = `repo:${repoName}`;
      if (canonicalNodes.has(repoId)) {
        for (const techName of techs) {
          const techId = `tech:${techName}`;
          if (!canonicalNodes.has(techId)) {
            canonicalNodes.set(techId, { id: techId, name: techName, label: techName, type: "Tecnologia" });
          }
          const linkKey = `${repoId}->usa_tecnologias->${techId}`;
          if (!canonicalLinks.has(linkKey)) {
            canonicalLinks.set(linkKey, { source: repoId, target: techId, relation: "usa_tecnologias", label: "usa_tecnologias" });
          }
        }
      }
    }

    try {
      const contractRows = targetRepository
        ? this.db.prepare("SELECT repository, module, method, path, document FROM contracts WHERE repository=?").all(targetRepository)
        : this.db.prepare("SELECT repository, module, method, path, document FROM contracts").all();
      for (const row of contractRows) {
        const repoId = `repo:${row.repository}`;
        const moduleId = `module:${row.module}`;
        const endpointName = `${row.method} ${row.path}`;
        const endpointId = `endpoint:${endpointName}`;

        if (!canonicalNodes.has(repoId)) {
          canonicalNodes.set(repoId, { id: repoId, name: row.repository, label: row.repository, type: "Repositorio" });
        }
        if (!canonicalNodes.has(moduleId)) {
          canonicalNodes.set(moduleId, { id: moduleId, name: row.module, label: row.module, type: "Modulo" });
        }
        if (!canonicalNodes.has(endpointId)) {
          let docObj = {};
          try { docObj = JSON.parse(row.document); } catch {}
          canonicalNodes.set(endpointId, {
            id: endpointId,
            name: endpointName,
            label: endpointName,
            type: "Endpoint",
            metodo: row.method,
            ruta: row.path,
            resumen: docObj.summary || "",
            autenticacion: docObj.authentication || "",
            version_api: docObj.api_version || "1.0.0",
            raw: docObj,
          });
        }

        const repoLinkKey = `${repoId}->contiene_modulos->${moduleId}`;
        if (!canonicalLinks.has(repoLinkKey)) {
          canonicalLinks.set(repoLinkKey, { source: repoId, target: moduleId, relation: "contiene_modulos", label: "contiene_modulos" });
        }

        const modLinkKey = `${moduleId}->expone_endpoints->${endpointId}`;
        if (!canonicalLinks.has(modLinkKey)) {
          canonicalLinks.set(modLinkKey, { source: moduleId, target: endpointId, relation: "expone_endpoints", label: "expone_endpoints" });
        }
      }
    } catch {}

    for (const id of ["repo:repositories", "repo:Repositorio 1", "repo:version", "repo:Repositorio"]) {
      if (canonicalNodes.has(id)) {
        const hasRelevantLinks = Array.from(canonicalLinks.values()).some((l) => l.source === id || l.target === id);
        if (!hasRelevantLinks) canonicalNodes.delete(id);
      }
    }

    return {
      nodes: Array.from(canonicalNodes.values()),
      links: Array.from(canonicalLinks.values()),
    };
  }

  scopeRepositoryGraph(graph, dataset, includeTechnical = false) {
    const nodeId = (value) => String(value?.id ?? value?.identifier ?? value ?? "");
    const relation = (link) => String(link.relation || link.label || link.relationship_name || link.edge_info?.relationship_name || "");
    const allowed = new Set(["contiene_modulos", "expone_endpoints", "usa_tecnologias"]);
    const roots = graph.nodes.filter((node) => node.type === "Repositorio" && String(node.name || node.nombre || "") === dataset.repository);
    const selected = new Set();
    for (const root of roots) {
      const id = nodeId(root);
      if (graph.links.some((link) => nodeId(link.source) === id && allowed.has(relation(link)))) selected.add(id);
    }
    for (let pass = 0; pass < 3; pass += 1) {
      for (const link of graph.links) {
        if (selected.has(nodeId(link.source)) && allowed.has(relation(link))) selected.add(nodeId(link.target));
      }
    }
    if (includeTechnical) {
      for (let pass = 0; pass < 2; pass += 1) {
        for (const link of graph.links) {
          const source = nodeId(link.source); const target = nodeId(link.target);
          if (selected.has(source) || selected.has(target)) { selected.add(source); selected.add(target); }
        }
      }
    }
    return {
      ...graph,
      nodes: graph.nodes.filter((node) => selected.has(nodeId(node))),
      links: graph.links.filter((link) => selected.has(nodeId(link.source)) && selected.has(nodeId(link.target))),
    };
  }

  close() { this.db.close(); }
}
