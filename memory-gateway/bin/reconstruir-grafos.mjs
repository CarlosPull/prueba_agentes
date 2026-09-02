#!/usr/bin/env node
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { MemoryGatewayCore } from "../lib/core.mjs";

const required = (name) => process.env[name] || (() => { throw new Error(`falta ${name}`); })();
const confirmed = process.argv.includes("--confirmar-limpieza");
if (!confirmed) throw new Error("operación destructiva no confirmada; usa --confirmar-limpieza");

const databasePath = required("MEMORY_GATEWAY_DB");
const technologiesPath = process.env.PRUEBA_AGENTES_PRIVATE_TECH_MEMORY
  || resolve(process.cwd(), ".private/tecnologias.json");
const backupRoot = process.env.MEMORY_GRAPH_BACKUP_DIR
  || resolve(process.cwd(), ".private/graph-backups");
const stamp = new Date().toISOString().replace(/[:.]/g, "-");
const backupDir = join(backupRoot, stamp);
mkdirSync(backupDir, { recursive: true, mode: 0o700 });

const core = new MemoryGatewayCore({
  databasePath,
  clientsPath: required("MEMORY_GATEWAY_CLIENTS"),
  openapiDir: required("MEMORY_GATEWAY_OPENAPI_DIR"),
  cogneeBaseUrl: required("COGNEE_BASE_URL"),
  cogneeApiKey: process.env.COGNEE_API_KEY || "",
  cogneeBearerToken: process.env.COGNEE_BEARER_TOKEN || "",
});

try {
  core.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  copyFileSync(databasePath, join(backupDir, basename(databasePath)));
  if (existsSync(technologiesPath)) copyFileSync(technologiesPath, join(backupDir, basename(technologiesPath)));

  const datasets = (await core.cognee.datasets()).filter((item) =>
    String(item.name || item.dataset_name || "").startsWith("prueba_agentes_"));
  const manifest = [];
  for (const dataset of datasets) {
    const id = String(dataset.id || dataset.dataset_id || "");
    const name = String(dataset.name || dataset.dataset_name || "");
    const graph = await core.cognee.visualize({ datasetId: id, full: true, maxNodes: 1000 });
    writeFileSync(join(backupDir, `${name}.json`), `${JSON.stringify({ dataset, graph }, null, 2)}\n`, { mode: 0o600 });
    manifest.push({ id, name, nodes: graph.nodes.length, links: graph.links.length });
  }
  writeFileSync(join(backupDir, "manifest.json"), `${JSON.stringify({ created_at: new Date().toISOString(), datasets: manifest }, null, 2)}\n`, { mode: 0o600 });

  for (const dataset of manifest) await core.cognee.deleteDataset(dataset.id);

  const technologyFile = existsSync(technologiesPath)
    ? JSON.parse(readFileSync(technologiesPath, "utf8")) : { repositories: {} };
  const prepared = core.prepareCanonicalRebuild(technologyFile.repositories || {});
  process.stdout.write(`Respaldo creado en ${backupDir}\n`);
  process.stdout.write(`Datasets anteriores eliminados: ${manifest.length}\n`);
  process.stdout.write(`Snapshots canónicos preparados: ${prepared.pending}\n`);

  while (core.pendingOutbox() > 0) {
    const result = await core.flushOutbox(1);
    if (result.indexed === 0) {
      const failed = core.db.prepare("SELECT entity_id,last_error FROM outbox ORDER BY created_at LIMIT 1").get();
      throw new Error(`no se pudo reconstruir ${failed?.entity_id || "el siguiente grafo"}: ${failed?.last_error || "error desconocido"}`);
    }
    process.stdout.write(`Indexados: ${result.indexed}; pendientes: ${result.pending}\n`);
  }
  process.stdout.write("Reconstrucción canónica completada.\n");
} finally {
  core.close();
}
