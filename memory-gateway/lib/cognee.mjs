import { createHash } from "node:crypto";

function errorBody(response, body) {
  return `HTTP ${response.status}: ${String(body || "").slice(0, 1000)}`;
}

export class CogneeClient {
  constructor({
    baseUrl = "", apiKey = "", bearerToken = "", searchType = "CHUNKS",
    addTimeoutMs = 60_000, cognifyTimeoutMs = 600_000, searchTimeoutMs = 300_000,
    fetchImpl = fetch,
  }) {
    this.baseUrl = baseUrl.replace(/\/$/, "");
    this.apiKey = apiKey;
    this.bearerToken = bearerToken;
    this.searchType = searchType;
    this.addTimeoutMs = addTimeoutMs;
    this.cognifyTimeoutMs = cognifyTimeoutMs;
    this.searchTimeoutMs = searchTimeoutMs;
    this.fetchImpl = fetchImpl;
  }

  get configured() { return Boolean(this.baseUrl); }

  headers(extra = {}) {
    const headers = { ...extra };
    if (this.apiKey) headers["X-Api-Key"] = this.apiKey;
    else if (this.bearerToken) headers.Authorization = `Bearer ${this.bearerToken}`;
    return headers;
  }

  dataset(entityId) {
    const readable = String(entityId).toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 48) || "memoria";
    const fingerprint = createHash("sha256").update(String(entityId)).digest("hex").slice(0, 12);
    return `prueba_agentes_${readable}_${fingerprint}`;
  }

  async index({ id, entityId, content, metadata }) {
    if (!this.configured) throw new Error("Cognee no está configurado");
    const dataset = this.dataset(entityId);
    const document = JSON.stringify({ memory_id: id, content, metadata });
    const form = new FormData();
    form.append("data", new Blob([document], { type: "application/json" }), `memoria-${id}.json`);
    form.append("datasetName", dataset);
    const addResponse = await this.fetchImpl(`${this.baseUrl}/api/v1/add`, {
      method: "POST", headers: this.headers(), body: form, signal: AbortSignal.timeout(this.addTimeoutMs),
    });
    const addBody = await addResponse.text();
    if (!addResponse.ok) throw new Error(errorBody(addResponse, addBody));

    const cognifyResponse = await this.fetchImpl(`${this.baseUrl}/api/v1/cognify`, {
      method: "POST",
      headers: this.headers({ "content-type": "application/json" }),
      body: JSON.stringify({ datasets: [dataset], run_in_background: false }),
      signal: AbortSignal.timeout(this.cognifyTimeoutMs),
    });
    const cognifyBody = await cognifyResponse.text();
    if (!cognifyResponse.ok) throw new Error(errorBody(cognifyResponse, cognifyBody));
    return { dataset };
  }

  async search({ entityId, query, topK = 15 }) {
    if (!this.configured) throw new Error("Cognee no está configurado");
    const dataset = this.dataset(entityId);
    const response = await this.fetchImpl(`${this.baseUrl}/api/v1/search`, {
      method: "POST",
      headers: this.headers({ "content-type": "application/json" }),
      body: JSON.stringify({ query, search_type: this.searchType, datasets: [dataset], top_k: topK }),
      signal: AbortSignal.timeout(this.searchTimeoutMs),
    });
    const raw = await response.text();
    if (!response.ok) throw new Error(errorBody(response, raw));
    try { return { dataset, result: JSON.parse(raw) }; }
    catch { throw new Error("Cognee devolvió una respuesta JSON inválida"); }
  }
}
