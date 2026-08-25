#!/usr/bin/env python3
"""Runtime pequeño para descubrir y coordinar agentes definidos en Markdown."""

from __future__ import annotations

import argparse
import json
import os
import re
import selectors
import shlex
import shutil
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parent.parent
AGENTS_DIR = ROOT / "agentes"
PROJECTS_DIR = ROOT / "proyectos"
ORCHESTRATOR_FILE = ROOT / "orquestador" / "ORQUESTADOR.md"
CONFIG_FILE = ROOT / ".orquestador" / "config.json"
VALID_NAME = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
CODEX_CANDIDATES = (
    Path("/Applications/ChatGPT.app/Contents/Resources/codex"),
    Path("/Applications/Codex.app/Contents/Resources/codex"),
)


def load_config() -> dict:
    if not CONFIG_FILE.exists():
        return {}
    try:
        return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        raise SystemExit(f"Configuración inválida: {CONFIG_FILE}") from None


def save_config(config: dict) -> None:
    CONFIG_FILE.parent.mkdir(exist_ok=True)
    CONFIG_FILE.write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def slugify(value: str) -> str:
    normalized = unicodedata.normalize("NFKD", value)
    ascii_value = normalized.encode("ascii", "ignore").decode("ascii").lower()
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_value).strip("-")
    return (slug[:60].rstrip("-") or "proyecto")


def create_project(objective: str, requested_name: Optional[str] = None) -> Path:
    PROJECTS_DIR.mkdir(exist_ok=True)
    if requested_name:
        validate_name(requested_name, "proyecto")
        path = PROJECTS_DIR / requested_name
        if path.exists():
            raise SystemExit(
                f"El proyecto {requested_name!r} ya existe. Usa otro nombre para evitar sobrescribirlo."
            )
    else:
        base = slugify(objective)
        path = PROJECTS_DIR / base
        suffix = 2
        while path.exists():
            path = PROJECTS_DIR / f"{base}-{suffix}"
            suffix += 1
    (path / "codigo" / "backend").mkdir(parents=True)
    (path / "codigo" / "frontend").mkdir(parents=True)
    return path


def requirements_markdown(value: dict) -> str:
    lines = [
        f"# Requisitos: {value['objective']}",
        "",
        f"Generado: {datetime.now().astimezone().isoformat(timespec='seconds')}",
        "",
        "## Supuestos",
        "",
    ]
    assumptions = value.get("assumptions") or ["No se registraron supuestos."]
    lines.extend(f"- {assumption}" for assumption in assumptions)
    lines.extend(["", "## Requisitos categorizados", ""])
    for requirement in value["requirements"]:
        lines.extend(
            [
                f"### {requirement['id']} — {requirement['title']}",
                "",
                f"- Categoría: `{requirement['category']}`",
                f"- Fase: `{requirement['phase']}`",
                f"- Agente: `{requirement['agent']}`",
                "",
                requirement["description"],
                "",
                "Criterios de aceptación:",
                "",
            ]
        )
        criteria = requirement["acceptance_criteria"] or ["Cumplir la descripción del requisito."]
        lines.extend(f"- [ ] {criterion}" for criterion in criteria)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def save_requirements(project: Path, value: dict) -> Path:
    path = project / "REQUISITOS.md"
    path.write_text(requirements_markdown(value), encoding="utf-8")
    return path


def save_results(project: Path, results: list[dict]) -> Path:
    lines = ["# Resultados de ejecución", ""]
    for result in results:
        if result.get("error"):
            lines.extend([f"## {result['agent']} — Error", "", result["error"], ""])
            continue
        requirement = result["requirement"]
        lines.extend(
            [
                f"## {requirement['id']} — {requirement['title']}",
                "",
                f"Agente: `{result['agent']}`",
                "",
            ]
        )
        for step in result["steps"]:
            lines.extend([f"### {step['subagent']}", "", step["result"], ""])
    path = project / "RESULTADOS.md"
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return path


def validate_name(name: str, kind: str) -> None:
    if not VALID_NAME.fullmatch(name):
        raise SystemExit(
            f"Nombre de {kind} inválido: {name!r}. "
            "Usa minúsculas, números y guiones; por ejemplo: dev-front."
        )


def markdown_bullets(values: list[str], fallback: str) -> str:
    items = values or [fallback]
    return "\n".join(f"- {item}" for item in items)


def create_agent(name: str, mission: str, skills: list[str]) -> Path:
    validate_name(name, "agente")
    path = AGENTS_DIR / name
    if path.exists():
        raise SystemExit(f"El agente {name!r} ya existe en {path}.")

    path.mkdir(parents=True)
    (path / "subagentes").mkdir()
    agent_text = f"""# Agente: {name}

## Nombre

{name}

## Misión

{mission}

## Skills

{markdown_bullets(skills, 'Añadir las capacidades específicas de este agente.')}

## Forma de trabajo

Analiza el contexto, divide el objetivo en subtareas y delega cuando exista un subagente apropiado. Verifica los resultados antes de finalizar.

## Subagentes

- Ninguno todavía.

## Criterio de terminado

El objetivo fue cumplido, validado y documentado; los riesgos o pendientes están declarados explícitamente.
"""
    memory_text = f"""# Memoria: {name}

Esta memoria contiene hechos persistentes y decisiones confirmadas del agente. No guardar secretos, tokens ni datos personales.

## Hechos

- No hay hechos registrados todavía.

## Decisiones

<!-- El runtime añade nuevas entradas debajo de esta línea. -->
"""
    (path / "AGENTE.md").write_text(agent_text, encoding="utf-8")
    (path / "memoria.md").write_text(memory_text, encoding="utf-8")
    return path


def add_subagent_reference(agent_file: Path, name: str, mission: str) -> None:
    source = agent_file.read_text(encoding="utf-8")
    heading = re.search(r"^##\s+Subagentes\s*$", source, re.MULTILINE | re.IGNORECASE)
    if not heading:
        source = source.rstrip() + f"\n\n## Subagentes\n\n- `{name}`: {mission}\n"
    else:
        rest = source[heading.end() :]
        next_heading = re.search(r"^##\s+", rest, re.MULTILINE)
        end = heading.end() + (next_heading.start() if next_heading else len(rest))
        current = source[heading.end() : end]
        current = re.sub(r"\n\s*-\s+Ninguno todavía\.\s*", "\n", current, flags=re.IGNORECASE)
        current = current.rstrip() + f"\n\n- `{name}`: {mission}\n\n"
        source = source[: heading.end()] + current + source[end:]
    agent_file.write_text(source, encoding="utf-8")


def create_subagent(agent_name: str, name: str, mission: str, skills: list[str]) -> Path:
    validate_name(name, "subagente")
    agent = get_agent(agent_name)
    path = agent.path / "subagentes" / f"{name}.md"
    if path.exists():
        raise SystemExit(f"El subagente {name!r} ya existe en {path}.")

    path.parent.mkdir(exist_ok=True)
    source = f"""# Subagente: {name}

## Misión

{mission}

## Skills

{markdown_bullets(skills, 'Añadir las capacidades específicas de este subagente.')}

## Entradas

Objetivo delegado, contexto del agente principal, memoria relevante y resultados previos de los que dependa.

## Salida

Resultado concreto, archivos afectados, validaciones realizadas, riesgos y dudas pendientes.
"""
    path.write_text(source, encoding="utf-8")
    add_subagent_reference(agent.path / "AGENTE.md", name, mission)
    return path


def section(text: str, title: str) -> str:
    match = re.search(rf"^##\s+{re.escape(title)}\s*$", text, re.MULTILINE | re.IGNORECASE)
    if not match:
        return ""
    rest = text[match.end() :]
    next_heading = re.search(r"^##\s+", rest, re.MULTILINE)
    return rest[: next_heading.start() if next_heading else None].strip()


def bullets(text: str) -> list[str]:
    return [m.group(1).strip().strip("`") for m in re.finditer(r"^\s*-\s+(.+)$", text, re.MULTILINE)]


@dataclass
class Subagent:
    name: str
    path: Path
    mission: str
    skills: list[str]


@dataclass
class Agent:
    name: str
    path: Path
    mission: str
    skills: list[str]
    subagents: list[Subagent]
    memory: Path


def read_agent(path: Path) -> Agent:
    source = (path / "AGENTE.md").read_text(encoding="utf-8")
    subs: list[Subagent] = []
    for sub_path in sorted((path / "subagentes").glob("*.md")) if (path / "subagentes").exists() else []:
        sub_source = sub_path.read_text(encoding="utf-8")
        subs.append(Subagent(sub_path.stem, sub_path, section(sub_source, "Misión"), bullets(section(sub_source, "Skills"))))
    return Agent(path.name, path, section(source, "Misión"), bullets(section(source, "Skills")), subs, path / "memoria.md")


def discover() -> dict[str, Agent]:
    return {p.name: read_agent(p) for p in sorted(AGENTS_DIR.iterdir()) if p.is_dir() and (p / "AGENTE.md").exists()}


def get_agent(name: str) -> Agent:
    agent = discover().get(name)
    if not agent:
        available = ", ".join(sorted(discover())) or "ninguno"
        raise SystemExit(f"Agente desconocido: {name}. Disponibles: {available}")
    return agent


def memory(agent: Agent) -> str:
    return agent.memory.read_text(encoding="utf-8") if agent.memory.exists() else "(memoria vacía)"


def plan(agent: Agent, task: str) -> dict:
    # El orden expresa dependencias del flujo; los nombres no determinan la secuencia.
    order = {"generador-codigo": 10, "qa": 20, "documentador": 30}
    ordered = sorted(agent.subagents, key=lambda item: (order.get(item.name, 100), item.name))
    return {"agent": agent.name, "task": task, "steps": [{"subagent": s.name, "mission": s.mission, "status": "pending"} for s in ordered]}


def print_plan(value: dict) -> None:
    print(f"Agente principal: {value['agent']}\nObjetivo: {value['task']}\n")
    for i, step in enumerate(value["steps"], 1):
        print(f"{i}. [{step['status']}] {step['subagent']}: {step['mission']}")


def find_codex() -> Optional[Path]:
    configured = os.getenv("CODEX_BIN")
    if configured and Path(configured).is_file():
        return Path(configured)
    executable = shutil.which("codex")
    if executable:
        return Path(executable)
    return next((path for path in CODEX_CANDIDATES if path.is_file()), None)


def app_server_request(method: str, params: Optional[dict] = None) -> dict:
    executable = find_codex()
    if not executable:
        raise SystemExit(
            "No se encontró Codex CLI. Instálalo o configura CODEX_BIN con la ruta del ejecutable."
        )
    process = subprocess.Popen(
        [str(executable), "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    def send(message: dict) -> None:
        assert process.stdin is not None
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()

    def receive(request_id: int, timeout: int = 30) -> dict:
        assert process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        try:
            while time.monotonic() < deadline:
                remaining = max(0, deadline - time.monotonic())
                if not selector.select(remaining):
                    break
                line = process.stdout.readline()
                if not line:
                    break
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if message.get("id") == request_id:
                    return message
        finally:
            selector.close()
        raise TimeoutError

    try:
        send(
            {
                "method": "initialize",
                "id": 0,
                "params": {
                    "clientInfo": {
                        "name": "orquestador_markdown",
                        "title": "Orquestador Markdown",
                        "version": "0.2.0",
                    }
                },
            }
        )
        initialize_response = receive(0)
        if "error" in initialize_response:
            raise SystemExit(
                f"Codex App Server no pudo inicializar: {initialize_response['error'].get('message')}"
            )
        send({"method": "initialized", "params": {}})
        send({"method": method, "id": 1, "params": params or {}})
        response = receive(1)
    except TimeoutError:
        raise SystemExit("Codex App Server no respondió dentro de 30 segundos.") from None
    finally:
        if process.stdin:
            process.stdin.close()
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

    if response and "error" in response:
        error = response["error"].get("message", "error desconocido")
        raise SystemExit(f"Codex App Server rechazó {method}: {error}")
    if response and "result" in response:
        return response["result"]
    raise SystemExit("No se pudo consultar Codex App Server: respuesta ausente")


def list_models() -> list[dict]:
    data = []
    cursor = None
    while True:
        params = {"limit": 100, "includeHidden": False}
        if cursor:
            params["cursor"] = cursor
        result = app_server_request("model/list", params)
        data.extend(result.get("data", []))
        cursor = result.get("nextCursor")
        if not cursor:
            return data


def configured_model() -> Optional[str]:
    return os.getenv("CODEX_MODEL") or load_config().get("model")


def print_models() -> None:
    selected = configured_model()
    models = list_models()
    if not models:
        print("No hay modelos visibles para la cuenta actual.")
        return
    for item in models:
        model_id = item.get("model") or item.get("id")
        marker = "*" if model_id == selected else " "
        default = " (predeterminado)" if item.get("isDefault") else ""
        efforts = ", ".join(
            effort.get("reasoningEffort", "")
            for effort in item.get("supportedReasoningEfforts", [])
        )
        effort_text = f" | razonamiento: {efforts}" if efforts else ""
        print(f"{marker} {model_id} — {item.get('displayName', model_id)}{default}{effort_text}")


def select_model(model: str) -> None:
    available = {
        item.get("model") or item.get("id") for item in list_models()
    }
    if model not in available:
        choices = ", ".join(sorted(value for value in available if value))
        raise SystemExit(f"Modelo no disponible: {model}. Disponibles: {choices}")
    config = load_config()
    config["model"] = model
    save_config(config)
    print(f"Modelo seleccionado: {model}")


def call_codex(
    prompt: str, sandbox: str = "read-only", cwd: Optional[Path] = None
) -> str:
    executable = find_codex()
    if not executable:
        raise SystemExit(
            "No se encontró Codex CLI. Instálalo o configura CODEX_BIN con la ruta del ejecutable."
        )
    command = [
        str(executable),
        "exec",
        "--ephemeral",
        "--sandbox",
        sandbox,
        "--color",
        "never",
        "--cd",
        str(cwd or ROOT),
        prompt,
    ]
    model = configured_model()
    if model:
        command[2:2] = ["--model", model]
    try:
        result = subprocess.run(command, text=True, capture_output=True, timeout=300)
    except subprocess.TimeoutExpired:
        raise SystemExit("Codex excedió el tiempo máximo de 5 minutos.") from None
    if result.returncode != 0:
        detail = result.stderr.strip().splitlines()
        message = detail[-1] if detail else "error desconocido"
        raise SystemExit(f"Codex no pudo completar la solicitud: {message}")
    output = result.stdout.strip()
    if not output:
        raise SystemExit("Codex terminó sin devolver una respuesta.")
    return output


def call_openai_api(
    prompt: str, sandbox: str = "read-only", cwd: Optional[Path] = None
) -> str:
    key = os.getenv("OPENAI_API_KEY")
    if not key:
        raise SystemExit("Falta OPENAI_API_KEY para el proveedor 'api'.")
    base = os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
    model = os.getenv("OPENAI_MODEL", "gpt-5.6")
    api_style = os.getenv("OPENAI_API_STYLE", "responses").lower()
    if api_style == "chat":
        endpoint = f"{base}/chat/completions"
        payload = {"model": model, "messages": [{"role": "user", "content": prompt}], "temperature": 0.2}
    elif api_style == "responses":
        endpoint = f"{base}/responses"
        payload = {"model": model, "input": prompt}
    else:
        raise SystemExit("OPENAI_API_STYLE debe ser 'responses' o 'chat'.")

    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            data = json.load(response)
    except urllib.error.HTTPError as error:
        try:
            detail = json.loads(error.read().decode()).get("error", {}).get("message", "")
        except (UnicodeDecodeError, json.JSONDecodeError):
            detail = ""
        message = f"OpenAI respondió HTTP {error.code}"
        raise SystemExit(f"{message}: {detail}" if detail else message) from None
    except urllib.error.URLError as error:
        raise SystemExit(f"No se pudo conectar con OpenAI: {error.reason}") from None

    if api_style == "chat":
        return data["choices"][0]["message"]["content"]
    if data.get("output_text"):
        return data["output_text"]
    for item in data.get("output", []):
        for content in item.get("content", []):
            if content.get("type") == "output_text" and content.get("text"):
                return content["text"]
    raise SystemExit("OpenAI respondió correctamente, pero no devolvió texto interpretable.")


def call_model(
    prompt: str, sandbox: str = "read-only", cwd: Optional[Path] = None
) -> str:
    provider = os.getenv("ORQUESTADOR_PROVIDER", "codex").lower()
    if provider == "codex":
        return call_codex(prompt, sandbox=sandbox, cwd=cwd)
    if provider == "api":
        return call_openai_api(prompt, sandbox=sandbox, cwd=cwd)
    raise SystemExit("ORQUESTADOR_PROVIDER debe ser 'codex' o 'api'.")


def authenticate() -> None:
    executable = find_codex()
    if not executable:
        raise SystemExit(
            "No se encontró Codex CLI. Instálalo desde https://developers.openai.com/codex/cli"
        )
    status = subprocess.run(
        [str(executable), "login", "status"], text=True, capture_output=True
    )
    status_text = "\n".join(part.strip() for part in (status.stdout, status.stderr) if part.strip())
    if status.returncode == 0 and "Logged in" in status_text:
        print(status_text)
        return
    print("Se abrirá el flujo oficial de inicio de sesión de ChatGPT.")
    result = subprocess.run([str(executable), "login"])
    if result.returncode != 0:
        raise SystemExit("No se pudo completar el inicio de sesión con ChatGPT.")


def auth_status() -> None:
    executable = find_codex()
    if not executable:
        raise SystemExit("No se encontró Codex CLI.")
    result = subprocess.run([str(executable), "login", "status"], text=True)
    if result.returncode != 0:
        raise SystemExit("No hay una sesión activa de ChatGPT.")


def logout() -> None:
    executable = find_codex()
    if not executable:
        raise SystemExit("No se encontró Codex CLI.")
    result = subprocess.run([str(executable), "logout"])
    if result.returncode != 0:
        raise SystemExit("No se pudo cerrar la sesión de ChatGPT.")
    print("Sesión de ChatGPT cerrada.")


def test_connection() -> None:
    result = call_model("Responde únicamente con las palabras: conexión correcta")
    provider = os.getenv("ORQUESTADOR_PROVIDER", "codex")
    print(f"Proveedor {provider!r} conectado. Respuesta del modelo: {result}")


def parse_json_object(text: str) -> dict:
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\s*```$", "", cleaned)
    start, end = cleaned.find("{"), cleaned.rfind("}")
    if start < 0 or end < start:
        raise SystemExit("El agente de requisitos no devolvió un objeto JSON.")
    try:
        return json.loads(cleaned[start : end + 1])
    except json.JSONDecodeError as error:
        raise SystemExit(f"El plan de requisitos contiene JSON inválido: {error}") from None


def agent_catalog(agents: dict[str, Agent]) -> str:
    entries = []
    for agent in agents.values():
        entries.append(
            f"- {agent.name}\n  Misión: {agent.mission}\n  Skills: {', '.join(agent.skills)}"
        )
    return "\n".join(entries)


def choose_agent(requirement: dict, agents: dict[str, Agent]) -> str:
    requested = str(requirement.get("agent", "")).strip()
    if requested in agents and requested != "requisitos":
        return requested
    category = str(requirement.get("category", "")).lower()
    preferred = {"backend": "dev-back", "frontend": "dev-front", "qa": "qa"}
    if preferred.get(category) in agents:
        return preferred[category]
    candidates = [agent for agent in agents.values() if agent.name != "requisitos"]
    if not candidates:
        raise SystemExit("No hay agentes ejecutores disponibles.")
    target_words = set(
        re.findall(
            r"[a-záéíóúñ0-9]+",
            f"{category} {requirement.get('title', '')} {requirement.get('description', '')}".lower(),
        )
    )
    return max(
        candidates,
        key=lambda agent: len(
            target_words
            & set(re.findall(r"[a-záéíóúñ0-9]+", f"{agent.mission} {' '.join(agent.skills)}".lower()))
        ),
    ).name


def normalize_requirements_plan(raw: dict, objective: str, agents: dict[str, Agent]) -> dict:
    requirements = raw.get("requirements")
    if not isinstance(requirements, list) or not requirements:
        raise SystemExit("El agente de requisitos no produjo requisitos ejecutables.")
    normalized = []
    for index, item in enumerate(requirements, 1):
        if not isinstance(item, dict):
            continue
        category = str(item.get("category", "general")).strip().lower()
        requirement = {
            "id": str(item.get("id") or f"REQ-{index:03d}"),
            "title": str(item.get("title") or f"Requisito {index}").strip(),
            "description": str(item.get("description") or "").strip(),
            "category": category,
            "acceptance_criteria": [
                str(value) for value in item.get("acceptance_criteria", []) if str(value).strip()
            ],
            "agent": str(item.get("agent", "")).strip(),
        }
        requirement["agent"] = choose_agent(requirement, agents)
        requirement["phase"] = 2 if category == "qa" else 1
        normalized.append(requirement)
    if not normalized:
        raise SystemExit("No se pudo normalizar ningún requisito.")
    return {
        "objective": objective,
        "assumptions": [str(value) for value in raw.get("assumptions", [])],
        "requirements": normalized,
    }


def build_requirements_plan(objective: str) -> dict:
    agents = discover()
    if not agents:
        raise SystemExit("No hay agentes disponibles para planificar el objetivo.")
    requirements_agent = agents.get("requisitos")
    analyst_context = requirements_agent.mission if requirements_agent else ORCHESTRATOR_FILE.read_text(encoding="utf-8")
    prompt = f"""Actúa como analista de requisitos del orquestador.

INSTRUCCIONES DEL ANALISTA:
{analyst_context}

OBJETIVO DEL USUARIO:
{objective}

AGENTES DISPONIBLES:
{agent_catalog(agents)}

Divide el objetivo en requisitos pequeños, independientes y ejecutables. Clasifica cada requisito principalmente como backend o frontend cuando corresponda. Asigna exactamente un agente existente según su misión y skills. El agente `requisitos` solo analiza y no debe recibir implementación. Diseña los requisitos backend y frontend para que puedan ejecutarse en paralelo, compartiendo contratos explícitos cuando sea necesario.

Devuelve exclusivamente JSON válido con esta forma:
{{
  "objective": "...",
  "assumptions": ["..."],
  "requirements": [
    {{
      "id": "REQ-001",
      "title": "...",
      "description": "...",
      "category": "backend|frontend|qa|general",
      "agent": "nombre-exacto-del-agente",
      "acceptance_criteria": ["criterio verificable"]
    }}
  ]
}}
"""
    raw = parse_json_object(call_model(prompt, sandbox="read-only"))
    return normalize_requirements_plan(raw, objective, agents)


def print_requirements_plan(value: dict) -> None:
    print(f"Objetivo: {value['objective']}")
    if value.get("assumptions"):
        print("Supuestos:")
        for assumption in value["assumptions"]:
            print(f"- {assumption}")
    print("\nRequisitos y asignaciones:")
    for requirement in value["requirements"]:
        print(
            f"- {requirement['id']} [fase {requirement['phase']} · {requirement['category']}] "
            f"{requirement['title']} → {requirement['agent']}"
        )
        print(f"  {requirement['description']}")
        for criterion in requirement["acceptance_criteria"]:
            print(f"  ✓ {criterion}")


def ordered_subagents(agent: Agent) -> list[Subagent]:
    order = {"generador-codigo": 10, "generador-ui": 10, "qa": 20, "documentador": 30}
    return sorted(agent.subagents, key=lambda item: (order.get(item.name, 100), item.name))


def requirement_workspace(project: Path, requirement: dict) -> Path:
    category = requirement["category"]
    if category == "backend":
        return project / "codigo" / "backend"
    if category == "frontend":
        return project / "codigo" / "frontend"
    return project / "codigo"


def run_requirement(
    agent: Agent, requirement: dict, shared_plan: dict, project: Path
) -> dict:
    criteria = "\n".join(f"- {item}" for item in requirement["acceptance_criteria"])
    shared_contracts = "\n".join(
        f"- {item['id']} [{item['category']}]: {item['title']} — {item['description']}"
        for item in shared_plan["requirements"]
    )
    workspace = requirement_workspace(project, requirement)
    workspace.mkdir(parents=True, exist_ok=True)
    context = f"""AGENTE PRINCIPAL: {agent.name}
MISIÓN: {agent.mission}
SKILLS: {', '.join(agent.skills)}
MEMORIA:
{memory(agent)}

REQUISITO ASIGNADO:
{requirement['id']} — {requirement['title']}
{requirement['description']}

CRITERIOS DE ACEPTACIÓN:
{criteria or '- Cumplir la descripción del requisito.'}

PLAN COMPARTIDO (otros agentes trabajan en paralelo):
{shared_contracts}

PROYECTO AISLADO: {project}
DIRECTORIO OBLIGATORIO DE TRABAJO: {workspace}

Todo archivo que generes o modifiques debe permanecer dentro de PROYECTO AISLADO. Para este requisito trabaja dentro de DIRECTORIO OBLIGATORIO DE TRABAJO. No escribas en la raíz del repositorio, `agentes/`, `runtime/`, `orquestador/` ni en otros proyectos. Inspecciona el directorio asignado, implementa los cambios necesarios, valida el resultado y evita modificar áreas asignadas a otros agentes. Informa archivos cambiados, pruebas y riesgos.
"""
    subagent_results = []
    subagents = ordered_subagents(agent)
    if not subagents:
        result = call_model(context, sandbox="workspace-write", cwd=workspace)
        subagent_results.append({"subagent": agent.name, "result": result})
    else:
        rolling_context = context
        for subagent in subagents:
            prompt = f"""Actúa como subagente `{subagent.name}`.
MISIÓN: {subagent.mission}
SKILLS: {', '.join(subagent.skills)}

{rolling_context}

Entrega un resultado concreto. No declares pruebas que no ejecutaste.
"""
            result = call_model(prompt, sandbox="workspace-write", cwd=workspace)
            subagent_results.append({"subagent": subagent.name, "result": result})
            rolling_context += f"\n\nRESULTADO DE {subagent.name}:\n{result}"
    return {"requirement": requirement, "agent": agent.name, "steps": subagent_results}


def orchestrate(
    objective: str,
    execute_tasks: bool = True,
    project_name: Optional[str] = None,
) -> dict:
    requirements_plan = build_requirements_plan(objective)
    project = create_project(objective, requested_name=project_name)
    requirements_path = save_requirements(project, requirements_plan)
    print_requirements_plan(requirements_plan)
    print(f"\nProyecto creado: {project.relative_to(ROOT)}")
    print(f"Requisitos guardados: {requirements_path.relative_to(ROOT)}")
    if not execute_tasks:
        return {"project": project, "plan": requirements_plan, "results": []}

    agents = discover()
    def run_assignment(agent_name: str, requirements: list[dict]) -> list[dict]:
        agent = agents[agent_name]
        return [
            run_requirement(agent, requirement, requirements_plan, project)
            for requirement in requirements
        ]

    results = []
    phases = sorted({requirement["phase"] for requirement in requirements_plan["requirements"]})
    for phase in phases:
        phase_requirements = [
            requirement
            for requirement in requirements_plan["requirements"]
            if requirement["phase"] == phase
        ]
        assignments: dict[str, list[dict]] = {}
        for requirement in phase_requirements:
            assignments.setdefault(requirement["agent"], []).append(requirement)
        print(
            f"\nFase {phase}: ejecutando {len(phase_requirements)} requisitos "
            f"en {len(assignments)} agentes paralelos..."
        )
        with ThreadPoolExecutor(max_workers=max(1, min(len(assignments), 8))) as executor:
            futures = {
                executor.submit(run_assignment, agent_name, requirements): agent_name
                for agent_name, requirements in assignments.items()
            }
            for future in as_completed(futures):
                agent_name = futures[future]
                try:
                    results.extend(future.result())
                    print(f"✓ {agent_name} terminó su asignación de fase {phase}")
                except (SystemExit, Exception) as error:
                    print(f"✗ {agent_name} falló en fase {phase}: {error}")
                    results.append({"agent": agent_name, "error": str(error), "steps": []})

    print("\nResultados consolidados:")
    for result in results:
        if result.get("error"):
            print(f"\n### {result['agent']} — ERROR\n{result['error']}")
            continue
        requirement = result["requirement"]
        print(f"\n### {requirement['id']} — {requirement['title']} ({result['agent']})")
        for step in result["steps"]:
            print(f"\n#### {step['subagent']}\n{step['result']}")
    results_path = save_results(project, results)
    print(f"\nResultados guardados: {results_path.relative_to(ROOT)}")
    return {"project": project, "plan": requirements_plan, "results": results}


def execute(agent: Agent, task: str) -> None:
    category = {"dev-back": "backend", "dev-front": "frontend", "qa": "qa"}.get(
        agent.name, "general"
    )
    requirement = {
        "id": "REQ-001",
        "title": task,
        "description": task,
        "category": category,
        "agent": agent.name,
        "acceptance_criteria": ["Cumplir el objetivo delegado y validar el resultado."],
        "phase": 1,
    }
    requirements_plan = {
        "objective": task,
        "assumptions": [f"Ejecución directa solicitada al agente {agent.name}."],
        "requirements": [requirement],
    }
    project = create_project(task)
    save_requirements(project, requirements_plan)
    result = run_requirement(agent, requirement, requirements_plan, project)
    save_results(project, [result])
    print(f"Ejecución coordinada para {agent.name}: {task}\n")
    print(f"Proyecto: {project.relative_to(ROOT)}")
    for step in result["steps"]:
        print(f"\n### {step['subagent']}\n{step['result']}")


CONSOLE_HELP = """Comandos disponibles:
  /login                         Iniciar o comprobar sesión de ChatGPT
  /logout                        Cerrar sesión de ChatGPT
  /status                        Mostrar estado de autenticación y modelo
  /models                        Listar modelos disponibles para tu cuenta
  /model <id>                    Seleccionar y guardar un modelo
  /agents                        Listar agentes
  /subagents <agente>            Listar subagentes
  /create-agent <nombre>         Crear un agente mediante preguntas
  /create-subagent <agente> <nombre>
                                 Crear un subagente mediante preguntas
  /requirements <objetivo>       Dividir, categorizar y asignar sin ejecutar
  /orchestrate <objetivo>        Planificar y ejecutar agentes en paralelo
  /plan <agente> <objetivo>      Mostrar el plan de ejecución
  /run <agente> <objetivo>       Ejecutar el flujo de subagentes
  /help                          Mostrar esta ayuda
  /exit                          Salir de la consola
"""


def print_agents() -> None:
    agents = discover()
    if not agents:
        print("No hay agentes creados.")
        return
    for name, agent in agents.items():
        print(f"- {name}: {len(agent.subagents)} subagentes")


def print_subagents(agent_name: str) -> None:
    agent = get_agent(agent_name)
    if not agent.subagents:
        print(f"El agente {agent_name} no tiene subagentes.")
        return
    for subagent in agent.subagents:
        print(f"- {subagent.name}: {subagent.mission}")


def prompt_skills() -> list[str]:
    value = input("Skills separadas por coma (opcional): ").strip()
    return [item.strip() for item in value.split(",") if item.strip()]


def console() -> None:
    print("Orquestador Markdown — escribe /help para ver los comandos.")
    while True:
        try:
            raw = input("orquesta> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nHasta luego.")
            return
        if not raw:
            continue
        try:
            parts = shlex.split(raw)
            command, arguments = parts[0].lower(), parts[1:]
            if command in {"/exit", "/salir"}:
                print("Hasta luego.")
                return
            if command in {"/help", "/ayuda"}:
                print(CONSOLE_HELP)
            elif command == "/login":
                authenticate()
            elif command == "/logout":
                confirmation = input("¿Cerrar la sesión de ChatGPT? [s/N]: ").strip().lower()
                if confirmation in {"s", "si", "sí", "y", "yes"}:
                    logout()
                else:
                    print("Operación cancelada.")
            elif command == "/status":
                auth_status()
                print(f"Modelo seleccionado: {configured_model() or 'predeterminado de Codex'}")
            elif command == "/models":
                print_models()
            elif command == "/model" and len(arguments) == 1:
                select_model(arguments[0])
            elif command == "/agents":
                print_agents()
            elif command == "/subagents" and len(arguments) == 1:
                print_subagents(arguments[0])
            elif command == "/create-agent" and len(arguments) == 1:
                mission = input("Misión del agente: ").strip()
                if not mission:
                    print("La misión es obligatoria.")
                    continue
                path = create_agent(arguments[0], mission, prompt_skills())
                print(f"Agente creado: {path.relative_to(ROOT)}")
            elif command == "/create-subagent" and len(arguments) == 2:
                mission = input("Misión del subagente: ").strip()
                if not mission:
                    print("La misión es obligatoria.")
                    continue
                path = create_subagent(arguments[0], arguments[1], mission, prompt_skills())
                print(f"Subagente creado: {path.relative_to(ROOT)}")
            elif command == "/requirements" and arguments:
                orchestrate(" ".join(arguments), execute_tasks=False)
            elif command == "/orchestrate" and arguments:
                orchestrate(" ".join(arguments), execute_tasks=True)
            elif command == "/plan" and len(arguments) >= 2:
                print_plan(plan(get_agent(arguments[0]), " ".join(arguments[1:])))
            elif command == "/run" and len(arguments) >= 2:
                execute(get_agent(arguments[0]), " ".join(arguments[1:]))
            else:
                print("Comando o argumentos inválidos. Escribe /help.")
        except SystemExit as error:
            print(error)
        except ValueError as error:
            print(f"Entrada inválida: {error}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Orquestador de agentes Markdown")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("consola", help="Abre una consola interactiva con comandos tipo /comando")
    orchestrate_command = commands.add_parser(
        "orquestar", help="Divide requisitos, asigna agentes y ejecuta en paralelo"
    )
    orchestrate_command.add_argument("objective")
    orchestrate_command.add_argument(
        "--solo-plan", action="store_true", help="No ejecuta agentes; solo muestra requisitos y asignaciones"
    )
    orchestrate_command.add_argument(
        "--proyecto", help="Nombre de carpeta dentro de proyectos/ (minúsculas y guiones)"
    )

    auth = commands.add_parser("auth", help="Gestiona la sesión de ChatGPT")
    auth_commands = auth.add_subparsers(dest="auth_command", required=True)
    auth_commands.add_parser("login")
    auth_commands.add_parser("logout")
    auth_commands.add_parser("status")

    models = commands.add_parser("modelos", help="Lista o selecciona modelos de Codex")
    model_commands = models.add_subparsers(dest="model_command", required=True)
    model_commands.add_parser("listar")
    use_model = model_commands.add_parser("usar")
    use_model.add_argument("model")
    model_commands.add_parser("actual")

    agents = commands.add_parser("agentes", help="Gestiona agentes")
    agent_commands = agents.add_subparsers(dest="agent_command", required=True)
    agent_commands.add_parser("listar")
    create_agent_command = agent_commands.add_parser("crear")
    create_agent_command.add_argument("name")
    create_agent_command.add_argument("--mision", required=True)
    create_agent_command.add_argument("--skill", action="append", default=[])
    show_agent = agent_commands.add_parser("ver")
    show_agent.add_argument("agent")

    subagents = commands.add_parser("subagentes", help="Gestiona subagentes")
    subagent_commands = subagents.add_subparsers(dest="subagent_command", required=True)
    list_subagents = subagent_commands.add_parser("listar")
    list_subagents.add_argument("agent")
    create_subagent_command = subagent_commands.add_parser("crear")
    create_subagent_command.add_argument("agent")
    create_subagent_command.add_argument("name")
    create_subagent_command.add_argument("--mision", required=True)
    create_subagent_command.add_argument("--skill", action="append", default=[])

    # Comandos originales conservados para no romper scripts existentes.
    commands.add_parser("listar")
    commands.add_parser("autenticar", help="Inicia o comprueba la sesión de ChatGPT mediante Codex")
    commands.add_parser("probar-conexion", help="Comprueba credenciales, red y modelo configurado")
    new_agent = commands.add_parser("crear-agente", help="Crea un agente, su memoria y carpeta de subagentes")
    new_agent.add_argument("name")
    new_agent.add_argument("--mision", required=True)
    new_agent.add_argument("--skill", action="append", default=[])
    new_subagent = commands.add_parser("crear-subagente", help="Crea un subagente dentro de un agente existente")
    new_subagent.add_argument("agent")
    new_subagent.add_argument("name")
    new_subagent.add_argument("--mision", required=True)
    new_subagent.add_argument("--skill", action="append", default=[])
    inspect = commands.add_parser("inspeccionar"); inspect.add_argument("agent")
    make_plan = commands.add_parser("plan"); make_plan.add_argument("agent"); make_plan.add_argument("task")
    run = commands.add_parser("ejecutar"); run.add_argument("agent"); run.add_argument("task")
    remember = commands.add_parser("recordar"); remember.add_argument("agent"); remember.add_argument("note")
    show_memory = commands.add_parser("memoria"); show_memory.add_argument("agent")
    args = parser.parse_args()
    if args.command == "consola":
        console()
    elif args.command == "orquestar":
        orchestrate(
            args.objective,
            execute_tasks=not args.solo_plan,
            project_name=args.proyecto,
        )
    elif args.command == "auth":
        if args.auth_command == "login": authenticate()
        elif args.auth_command == "logout": logout()
        elif args.auth_command == "status": auth_status()
    elif args.command == "modelos":
        if args.model_command == "listar": print_models()
        elif args.model_command == "usar": select_model(args.model)
        elif args.model_command == "actual": print(configured_model() or "predeterminado de Codex")
    elif args.command == "agentes":
        if args.agent_command == "listar": print_agents()
        elif args.agent_command == "crear":
            path = create_agent(args.name, args.mision, args.skill)
            print(f"Agente creado: {path.relative_to(ROOT)}")
        elif args.agent_command == "ver":
            agent = get_agent(args.agent)
            print(f"{agent.name}: {agent.mission}\nSkills: {', '.join(agent.skills)}\nSubagentes: {', '.join(s.name for s in agent.subagents)}")
    elif args.command == "subagentes":
        if args.subagent_command == "listar": print_subagents(args.agent)
        elif args.subagent_command == "crear":
            path = create_subagent(args.agent, args.name, args.mision, args.skill)
            print(f"Subagente creado: {path.relative_to(ROOT)}")
    elif args.command == "listar":
        print_agents()
    elif args.command == "autenticar":
        authenticate()
    elif args.command == "probar-conexion":
        test_connection()
    elif args.command == "crear-agente":
        path = create_agent(args.name, args.mision, args.skill)
        print(f"Agente creado: {path.relative_to(ROOT)}")
    elif args.command == "crear-subagente":
        path = create_subagent(args.agent, args.name, args.mision, args.skill)
        print(f"Subagente creado: {path.relative_to(ROOT)}")
    elif args.command == "inspeccionar":
        agent = get_agent(args.agent); print(f"{agent.name}: {agent.mission}\nSkills: {', '.join(agent.skills)}\nSubagentes: {', '.join(s.name for s in agent.subagents)}")
    elif args.command == "plan": print_plan(plan(get_agent(args.agent), args.task))
    elif args.command == "ejecutar": execute(get_agent(args.agent), args.task)
    elif args.command == "memoria": print(memory(get_agent(args.agent)))
    elif args.command == "recordar":
        agent = get_agent(args.agent)
        with agent.memory.open("a", encoding="utf-8") as file: file.write(f"\n- {args.note}\n")
        print(f"Memoria actualizada: {agent.memory.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
