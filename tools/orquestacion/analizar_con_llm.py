#!/usr/bin/env python3
import sys, json, urllib.request


class DestinoInvalido(ValueError):
    """Una respuesta del modelo no puede ampliar el inventario autorizado."""


def enriquecer_requisitos(reqs, inventory):
    if not isinstance(reqs, list) or not reqs or len(reqs) > 100:
        raise DestinoInvalido("Lista de requisitos inválida")
    inv_map = {}
    for item in inventory:
        key = (item["profile"], item["repository"])
        if key in inv_map:
            raise DestinoInvalido("Destino duplicado en el inventario")
        inv_map[key] = item
    enriched = []
    for i, r in enumerate(reqs, start=1):
        if not isinstance(r, dict):
            raise DestinoInvalido("Requisito inválido")
        if not all(isinstance(r.get(field), str) for field in ["target_profile", "repository", "module", "category"]):
            raise DestinoInvalido("Identificadores del destino inválidos")
        inv_item = inv_map.get((r.get("target_profile"), r.get("repository")))
        if inv_item is None:
            raise DestinoInvalido("Perfil/repositorio ajeno al inventario")
        if r.get("category") != inv_item["stack"] or r.get("module") != inv_item["module"]:
            raise DestinoInvalido("Categoría o módulo no coincide con el destino")
        if not isinstance(r.get("text"), str) or not r["text"].strip() or len(r["text"]) > 20000:
            raise DestinoInvalido("Texto del requisito inválido")
        enriched.append({
            "id": f"REQ-{i:03d}", "category": inv_item["stack"], "text": r["text"],
            "target_profile": inv_item["profile"], "repository": inv_item["repository"],
            "module": inv_item["module"], "repository_kind": inv_item.get("kind"),
            "workspace": inv_item["workspace"],
            "technology_constraints": inv_item.get("technology"), "depends_on": []
        })
    return enriched

def main():
    if len(sys.argv) < 3:
        sys.exit(1)
    
    prompt_user = sys.argv[1]
    context_file = sys.argv[2]

    try:
        with open(context_file, "r", encoding="utf-8") as f:
            context_data = json.load(f)
    except Exception:
        sys.exit(1)

    inventory = context_data.get("inventory", [])
    if not inventory:
        sys.exit(1)

    inventory_summary = []
    for item in inventory:
        inventory_summary.append({
            "profile": item.get("profile"),
            "repository": item.get("repository"),
            "module": item.get("module"),
            "stack": item.get("stack"),
            "kind": item.get("kind"),
            "aliases": item.get("aliases", []),
            "technology": item.get("technology", {})
        })

    system_prompt = f"""Eres el analista de requisitos inteligente de un orquestador distribuido multi-repositorio.
Analiza el prompt del usuario y divídelo en los requisitos necesarios asignados AL PERFIL O PERFILES MÁS ADECUADOS.

Inventario de repositorios y perfiles disponibles:
{json.dumps(inventory_summary, ensure_ascii=False)}

REGLAS DE ORO:
1. Si el usuario pide crear elementos UI (componentes Vue, botones, modales, vistas, dashboards) en el frontend que consumen servicios/endpoints existentes (ej: 'según los endpoints de posts crea un botón/modal...'), asigna la tarea ÚNICAMENTE al perfil 'frontend'. NO generes requisitos backend adicionales a menos que la solicitud pida explícitamente CREAR O MODIFICAR un endpoint backend (ej: 'crea un endpoint POST /api/v1/posts y un botón en Vue').
2. Si el usuario pide explícitamente cambios en varios módulos (ej: 'crea un endpoint en posts y un componente en frontend'), genera requisitos separados para cada perfil correspondiente.
3. Asigna únicamente a repositorios y perfiles presentes en el inventario.


{{
  "requirements": [
    {{
      "category": "frontend|backend",
      "target_profile": "<profile_id>",
      "repository": "<repository_id>",
      "module": "<module_id>",
      "text": "<descripcion_clara_y_especifica_de_la_subtarea>"
    }}
  ]
}}"""

    payload = json.dumps({
        "model": "hermes3:latest",
        "prompt": system_prompt + "\n\nSolicitud del usuario:\n\"" + prompt_user + "\"",
        "stream": False,
        "format": "json"
    }).encode("utf-8")

    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"}
    )

    try:
        with urllib.request.urlopen(req, timeout=12) as response:
            res_raw = response.read().decode("utf-8")
            res_json = json.loads(res_raw)
            model_out = json.loads(res_json.get("response", "{}"))
            enriched = enriquecer_requisitos(model_out.get("requirements"), inventory)

            print(json.dumps(enriched, ensure_ascii=False, indent=2))
            sys.exit(0)

    except DestinoInvalido as error:
        print(f"ROUTING_LLM_RECHAZADO: {error}", file=sys.stderr)
        sys.exit(3)
    except Exception:
        sys.exit(1)

if __name__ == "__main__":
    main()
