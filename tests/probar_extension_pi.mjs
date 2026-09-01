import {
  appendFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";
import piHarnessPolicy from "../pi-harness/extension/index.ts";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const temporary = mkdtempSync(join(tmpdir(), "prueba-extension-pi."));
try {
  const workspace = join(temporary, "workspace");
  const outside = join(temporary, "fuera");
  const policyPath = join(temporary, "backend.json");
  const auditPath = join(temporary, "audit.jsonl");
  mkdirSync(join(workspace, "app"), { recursive: true });
  mkdirSync(join(workspace, "resources", "js"), { recursive: true });
  mkdirSync(outside, { recursive: true });
  writeFileSync(join(workspace, "app", "Allowed.php"), "<?php\n");
  writeFileSync(join(workspace, ".env"), "SECRETO=1\n");
  writeFileSync(join(outside, "secret.txt"), "secreto\n");
  symlinkSync(outside, join(workspace, "app", "escape"));
  appendFileSync(auditPath, "");
  writeFileSync(
    policyPath,
    JSON.stringify({
      version: 1,
      role: "backend",
      read: ["app/**"],
      write: ["app/**"],
      deny_read: [".env", "all other workspace paths"],
      deny_write: [".env", "all other workspace paths"],
    }),
  );

  process.env.PI_HARNESS_WORKSPACE = workspace;
  process.env.PI_HARNESS_POLICY = policyPath;
  process.env.PI_HARNESS_AUDIT_FILE = auditPath;
  process.env.PI_HARNESS_ROLE = "backend";
  process.env.PI_HARNESS_PLATFORM = "linux";
  process.env.PI_HARNESS_SANDBOX_BACKEND = "bwrap";
  process.env.PI_HARNESS_SANDBOX_ENFORCED = "1";
  delete process.env.PI_HARNESS_READ_ONLY;

  let toolCallHandler;
  piHarnessPolicy({
    on(event, handler) {
      if (event === "tool_call") toolCallHandler = handler;
    },
  });
  assert(typeof toolCallHandler === "function", "la extensión no registró tool_call");

  const allowedRead = await toolCallHandler({ toolName: "read", input: { path: "app/Allowed.php" } });
  assert(allowedRead === undefined, "se bloqueó una lectura permitida");

  const deniedSecret = await toolCallHandler({ toolName: "read", input: { path: ".env" } });
  assert(deniedSecret?.block === true, "se permitió leer .env");

  const deniedFrontend = await toolCallHandler({ toolName: "write", input: { path: "resources/js/App.vue" } });
  assert(deniedFrontend?.block === true, "backend pudo escribir en frontend");

  const allowedWrite = await toolCallHandler({ toolName: "write", input: { path: "app/Nuevo.php" } });
  assert(allowedWrite === undefined, "se bloqueó una escritura permitida en modo normal");

  const deniedSymlink = await toolCallHandler({ toolName: "read", input: { path: "app/escape/secret.txt" } });
  assert(deniedSymlink?.block === true, "un enlace simbólico escapó del workspace");

  const allowedBash = await toolCallHandler({ toolName: "bash", input: { command: "pwd" } });
  assert(allowedBash === undefined, "bash fue bloqueado pese al aislamiento activo");

  const allowedPowerShell = await toolCallHandler({ toolName: "powershell", input: { command: "Get-Location" } });
  assert(allowedPowerShell === undefined, "PowerShell fue bloqueado pese al aislamiento activo");

  const unknownTool = await toolCallHandler({ toolName: "otra", input: {} });
  assert(unknownTool?.block === true, "una herramienta desconocida fue permitida");

  process.env.PI_HARNESS_READ_ONLY = "1";
  let readOnlyHandler;
  piHarnessPolicy({
    on(event, handler) {
      if (event === "tool_call") readOnlyHandler = handler;
    },
  });
  const deniedReadOnlyWrite = await readOnlyHandler({ toolName: "write", input: { path: "app/Nuevo.php" } });
  assert(deniedReadOnlyWrite?.block === true, "el modo solo lectura permitió una escritura autorizada por la política base");
  delete process.env.PI_HARNESS_READ_ONLY;

  const auditLines = readFileSync(auditPath, "utf8").trim().split("\n").filter(Boolean);
  assert(auditLines.length === 9, "la auditoría no contiene todas las decisiones");
  assert(auditLines.every((line) => JSON.parse(line).role === "backend"), "la auditoría perdió el rol");
} finally {
  rmSync(temporary, { recursive: true, force: true });
}

console.log("OK: política de herramientas, denegaciones y enlaces simbólicos verificados.");
