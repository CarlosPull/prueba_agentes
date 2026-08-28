import {
  appendFileSync,
  existsSync,
  lstatSync,
  readFileSync,
  realpathSync,
} from "node:fs";
import { isAbsolute, relative, resolve, sep } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Policy = {
  version: number;
  role: string;
  read: string[];
  write: string[];
  deny_read: string[];
  deny_write: string[];
};

type Access = "read" | "write";

const READ_TOOLS = new Set(["read", "grep", "find", "ls"]);
const WRITE_TOOLS = new Set(["write", "edit"]);

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Pi harness: falta la variable obligatoria ${name}`);
  }
  return value;
}

function isWithin(parent: string, child: string): boolean {
  const candidate = relative(parent, child);
  return candidate === "" || (!candidate.startsWith(`..${sep}`) && candidate !== ".." && !isAbsolute(candidate));
}

function normalizeRule(rule: string): string {
  return rule.endsWith("/**") ? rule.slice(0, -3) : rule;
}

function matchesRule(relativePath: string, rule: string): boolean {
  if (rule === "all other workspace paths") return false;
  const normalized = normalizeRule(rule).replaceAll("\\", "/").replace(/^\.\//, "");
  const candidate = relativePath.replaceAll("\\", "/").replace(/^\.\//, "");
  if (rule.endsWith("/**")) {
    return candidate === normalized || candidate.startsWith(`${normalized}/`);
  }
  return candidate === normalized;
}

function resolveInsideWorkspace(workspace: string, requestedPath: string): { absolute: string; relativePath: string } {
  const absolute = resolve(workspace, requestedPath || ".");
  if (!isWithin(workspace, absolute)) {
    throw new Error("la ruta sale del workspace");
  }

  // Se revisa cada componente existente. Así, un enlace simbólico no puede
  // apuntar fuera del workspace aunque el destino final todavía no exista.
  let cursor = workspace;
  const components = relative(workspace, absolute).split(sep).filter(Boolean);
  for (const component of components) {
    cursor = resolve(cursor, component);
    if (!existsSync(cursor)) continue;
    const resolved = realpathSync(cursor);
    if (!isWithin(workspace, resolved)) {
      throw new Error(`un enlace simbólico sale del workspace: ${cursor}`);
    }
    if (lstatSync(cursor).isSymbolicLink()) cursor = resolved;
  }

  const effective = existsSync(absolute) ? realpathSync(absolute) : absolute;
  if (!isWithin(workspace, effective)) {
    throw new Error("la ruta resuelta sale del workspace");
  }
  return {
    absolute: effective,
    relativePath: relative(workspace, effective).replaceAll("\\", "/") || ".",
  };
}

export default function piHarnessPolicy(pi: ExtensionAPI) {
  const workspace = realpathSync(requiredEnvironment("PI_HARNESS_WORKSPACE"));
  const policyPath = requiredEnvironment("PI_HARNESS_POLICY");
  const auditFile = requiredEnvironment("PI_HARNESS_AUDIT_FILE");
  const role = requiredEnvironment("PI_HARNESS_ROLE");
  const sandboxEnforced = process.env.PI_HARNESS_SANDBOX_ENFORCED === "1";
  const policy = JSON.parse(readFileSync(policyPath, "utf8")) as Policy;

  if (policy.version !== 1 || policy.role !== role) {
    throw new Error(`Pi harness: la política no corresponde al rol ${role}`);
  }

  function audit(tool: string, access: Access | "execute", path: string | null, allowed: boolean, reason: string) {
    appendFileSync(
      auditFile,
      `${JSON.stringify({
        timestamp: new Date().toISOString(),
        role,
        tool,
        access,
        path,
        allowed,
        reason,
        platform: process.env.PI_HARNESS_PLATFORM,
        sandbox_backend: process.env.PI_HARNESS_SANDBOX_BACKEND,
      })}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
  }

  function authorize(tool: string, access: Access, requestedPath: string) {
    try {
      const target = resolveInsideWorkspace(workspace, requestedPath);
      const deniedRules = access === "read" ? policy.deny_read : policy.deny_write;
      const allowedRules = access === "read" ? policy.read : policy.write;
      const denied = deniedRules.some((rule) => matchesRule(target.relativePath, rule));
      const allowed = !denied && allowedRules.some((rule) => matchesRule(target.relativePath, rule));
      const reason = denied
        ? `ruta denegada explícitamente por la política de ${role}`
        : allowed
          ? `ruta permitida por la política de ${role}`
          : `ruta fuera de la lista permitida para ${role}`;
      audit(tool, access, target.relativePath, allowed, reason);
      return allowed ? undefined : { block: true as const, reason };
    } catch (error) {
      const reason = error instanceof Error ? error.message : "ruta no válida";
      audit(tool, access, requestedPath, false, reason);
      return { block: true as const, reason: `Acceso bloqueado: ${reason}` };
    }
  }

  pi.on("tool_call", async (event) => {
    const input = (event.input ?? {}) as Record<string, unknown>;
    if (READ_TOOLS.has(event.toolName)) {
      return authorize(event.toolName, "read", typeof input.path === "string" ? input.path : ".");
    }
    if (WRITE_TOOLS.has(event.toolName)) {
      if (typeof input.path !== "string" || input.path.length === 0) {
        const reason = "la herramienta no indicó una ruta válida";
        audit(event.toolName, "write", null, false, reason);
        return { block: true, reason };
      }
      return authorize(event.toolName, "write", input.path);
    }
    if (event.toolName === "bash" || event.toolName === "powershell") {
      const allowed = sandboxEnforced;
      const reason = allowed
        ? "la orden será limitada por el aislamiento del sistema operativo"
        : "no existe evidencia de una barrera del sistema operativo activa";
      audit(event.toolName, "execute", null, allowed, reason);
      return allowed ? undefined : { block: true, reason };
    }

    const reason = `herramienta no reconocida por la política: ${event.toolName}`;
    audit(event.toolName, "execute", null, false, reason);
    return { block: true, reason };
  });
}
