import {
  appendFileSync,
  closeSync,
  existsSync,
  lstatSync,
  readFileSync,
  realpathSync,
  unlinkSync,
} from "node:fs";
import { request as httpsRequest } from "node:https";
import { isAbsolute, relative, resolve, sep } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Policy = {
  version: number;
  role: string;
  read: string[];
  write: string[];
  deny_read: string[];
  deny_write: string[];
  memory?: Record<string, Access[]>;
};

type Access = "read" | "write";

const READ_TOOLS = new Set(["read", "grep", "find", "ls"]);
const WRITE_TOOLS = new Set(["write", "edit"]);
const MEMORY_TOOLS = new Set(["memoria_buscar", "memoria_publicar_endpoint"]);

type GatewayCredentials = { ca: Buffer; cert: Buffer; key: Buffer };

function consumeCredential(fdName: string, fileName: string): Buffer {
  const rawFd = process.env[fdName];
  const credentialFile = process.env[fileName];
  delete process.env[fdName];
  delete process.env[fileName];

  if (rawFd) {
    const fd = Number(rawFd);
    if (!Number.isInteger(fd) || fd < 3) throw new Error(`Pi harness: descriptor inválido para ${fdName}`);
    try { return readFileSync(fd); } finally { closeSync(fd); }
  }
  if (credentialFile) {
    try { return readFileSync(credentialFile); }
    finally { unlinkSync(credentialFile); }
  }
  throw new Error(`Pi harness: falta la credencial ${fdName} o ${fileName}`);
}

function gatewayRequest(baseUrl: string, credentials: GatewayCredentials, path: string, body: unknown, signal?: AbortSignal): Promise<unknown> {
  return new Promise((resolveRequest, rejectRequest) => {
    const target = new URL(path, `${baseUrl.replace(/\/$/, "")}/`);
    if (target.protocol !== "https:") throw new Error("Memory Gateway requiere HTTPS");
    const request = httpsRequest(
      {
        protocol: target.protocol,
        hostname: target.hostname,
        port: target.port || 443,
        path: target.pathname,
        method: "POST",
        headers: { "content-type": "application/json" },
        ca: credentials.ca,
        cert: credentials.cert,
        key: credentials.key,
        minVersion: "TLSv1.3",
        rejectUnauthorized: true,
        signal,
      },
      (response) => {
        let raw = "";
        response.setEncoding("utf8");
        response.on("data", (chunk) => { raw += chunk; });
        response.on("end", () => {
          let parsed: unknown;
          try { parsed = JSON.parse(raw); } catch { parsed = { error: raw }; }
          if ((response.statusCode ?? 500) >= 400) {
            rejectRequest(new Error(`Memory Gateway rechazó la operación (${response.statusCode}): ${raw.slice(0, 1000)}`));
            return;
          }
          resolveRequest(parsed);
        });
      },
    );
    request.on("error", rejectRequest);
    request.end(JSON.stringify(body));
  });
}

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
  const readOnly = process.env.PI_HARNESS_READ_ONLY === "1";
  const gatewayUrl = process.env.PI_MEMORY_GATEWAY_URL || "";
  const coreId = process.env.PI_MEMORY_CORE_ID || "";
  const tenantId = process.env.PI_MEMORY_TENANT_ID || "";
  const memoryEnabled = process.env.PI_MEMORY_ENABLED === "1";
  let gatewayCredentials: GatewayCredentials | null = null;
  if (memoryEnabled && gatewayUrl) {
    gatewayCredentials = {
      key: consumeCredential("PI_MEMORY_TLS_KEY_FD", "PI_MEMORY_TLS_KEY_FILE"),
      cert: consumeCredential("PI_MEMORY_TLS_CERT_FD", "PI_MEMORY_TLS_CERT_FILE"),
      ca: consumeCredential("PI_MEMORY_TLS_CA_FD", "PI_MEMORY_TLS_CA_FILE"),
    };
  }
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
      if (readOnly && access === "write") {
        const reason = "la ejecución fue declarada de solo lectura";
        audit(tool, access, requestedPath, false, reason);
        return { block: true as const, reason };
      }
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

  function memoryAllowed(layer: string, access: Access): boolean {
    return Boolean(gatewayCredentials && !(readOnly && access === "write") && policy.memory?.[layer]?.includes(access));
  }

  if (gatewayCredentials) {
    pi.registerTool({
      name: "memoria_buscar",
      label: "Buscar mediante Memory Gateway",
      description: "Busca contexto autorizado en memoria compartida, de negocio o interna.",
      parameters: {
        type: "object",
        additionalProperties: false,
        required: ["layer", "query"],
        properties: {
          layer: { type: "string", enum: ["shared_contracts", "business", "company"] },
          query: { type: "string", minLength: 1, maxLength: 4000 },
        },
      } as any,
      async execute(_toolCallId, params, signal) {
        const layer = String(params.layer || "");
        try {
          if (!memoryAllowed(layer, "read")) throw new Error(`Acceso de lectura denegado a ${layer}`);
          const result = await gatewayRequest(gatewayUrl, gatewayCredentials, "/v1/memory/search", {
            layer, query: params.query, core_id: coreId, tenant_id: tenantId,
          }, signal);
          audit("memoria_buscar", "read", layer, true, `consulta Gateway autorizada para ${role}`);
          return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }], details: { layer } };
        } catch (error) {
          const reason = error instanceof Error ? error.message : "falló la consulta de memoria";
          audit("memoria_buscar", "read", layer, false, reason);
          throw error;
        }
      },
    });

    if (memoryAllowed("shared_contracts", "write")) {
      pi.registerTool({
        name: "memoria_publicar_endpoint",
        label: "Publicar endpoint en Memory Gateway",
        description: "Publica exclusivamente el contrato técnico de un endpoint; no acepta lógica de negocio ni código fuente.",
        parameters: {
          type: "object",
          additionalProperties: false,
          required: ["method", "path", "repository", "module", "summary"],
          properties: {
            method: { type: "string", enum: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"] },
            path: { type: "string", pattern: "^/", maxLength: 500 },
            repository: { type: "string", maxLength: 100 },
            module: { type: "string", maxLength: 100 },
            summary: { type: "string", maxLength: 1000 },
            authentication: { type: "string", maxLength: 1000 },
            request_schema: { type: "string", maxLength: 4000 },
            response_schema: { type: "string", maxLength: 4000 },
            version: { type: "string", maxLength: 100 },
            source_commit: { type: "string", maxLength: 100 },
          },
        } as any,
        async execute(_toolCallId, params, signal) {
          try {
            const result = await gatewayRequest(gatewayUrl, gatewayCredentials, "/v1/contracts/endpoints", {
              core_id: coreId, endpoint: params,
            }, signal);
            audit("memoria_publicar_endpoint", "write", "shared_contracts", true, "contrato publicado mediante Memory Gateway");
            return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }], details: { layer: "shared_contracts" } };
          } catch (error) {
            const reason = error instanceof Error ? error.message : "falló la publicación del endpoint";
            audit("memoria_publicar_endpoint", "write", "shared_contracts", false, reason);
            throw error;
          }
        },
      });
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
    if (MEMORY_TOOLS.has(event.toolName)) {
      const layer = event.toolName === "memoria_publicar_endpoint"
        ? "shared_contracts"
        : typeof input.layer === "string" ? input.layer : "";
      const access: Access = event.toolName === "memoria_publicar_endpoint" ? "write" : "read";
      const allowed = memoryAllowed(layer, access);
      const reason = allowed
        ? "operación controlada por la política y Memory Gateway"
        : `acceso ${access} denegado a la capa ${layer || "no indicada"}`;
      audit(event.toolName, "execute", null, allowed, reason);
      return allowed ? undefined : { block: true, reason };
    }

    const reason = `herramienta no reconocida por la política: ${event.toolName}`;
    audit(event.toolName, "execute", null, false, reason);
    return { block: true, reason };
  });
}
