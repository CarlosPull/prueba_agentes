# Orquestador de agentes

Arquitectura local inspirada en Letta para definir agentes, subagentes y memoria usando archivos Markdown.

## Estructura

```text
orquestador/
  ORQUESTADOR.md       # instrucciones y reglas del coordinador
agentes/
  dev-back/
    AGENTE.md          # identidad, skills y subagentes disponibles
    memoria.md         # memoria persistente de largo plazo
    subagentes/
      generador-codigo.md
      qa.md
      documentador.md
runtime/
  orquestador.py       # CLI y motor de descubrimiento/delegación
proyectos/
  <nombre>/
    REQUISITOS.md      # requisitos categorizados y asignaciones
    RESULTADOS.md      # reporte de la ejecución completa
    codigo/
      backend/         # aplicación PHP/Laravel
      frontend/        # aplicación Vue
```

## Uso

Requiere Python 3.10 o posterior.

```bash
./bin/orquesta consola
```

Dentro de la consola están disponibles:

```text
/login
/logout
/status
/models
/model <id>
/agents
/subagents <agente>
/create-agent <nombre>
/create-subagent <agente> <nombre>
/requirements <objetivo>
/orchestrate <objetivo>
/plan <agente> <objetivo>
/run <agente> <objetivo>
/help
/exit
```

También puedes usar comandos directos, adecuados para scripts:

```bash
./bin/orquesta auth login
./bin/orquesta auth status
./bin/orquesta auth logout

./bin/orquesta modelos listar
./bin/orquesta modelos usar gpt-5.6-sol
./bin/orquesta modelos actual

./bin/orquesta agentes listar
./bin/orquesta agentes crear dev-front \
  --mision "Construir interfaces web accesibles" \
  --skill "Vue 3 y TypeScript"

./bin/orquesta subagentes listar dev-front
./bin/orquesta subagentes crear dev-front generador-ui \
  --mision "Implementar componentes y páginas" \
  --skill "Vue 3"
```

La lista de modelos se obtiene de Codex App Server para la cuenta autenticada. La selección se guarda en `.orquestador/config.json`, carpeta ignorada por Git. `plan` funciona sin conexión; `ejecutar` usa Codex y la sesión de ChatGPT por defecto.

## Orquestación automática y paralela

Para analizar un objetivo sin modificar archivos:

```bash
./bin/orquesta orquestar "Genera un login" --solo-plan
```

Para planificar y ejecutar:

```bash
./bin/orquesta orquestar "Genera un login"
```

Puedes indicar un nombre explícito para el proyecto:

```bash
./bin/orquesta orquestar "Genera un login" --proyecto sistema-login
```

Si no indicas `--proyecto`, se genera un nombre desde el prompt y se añade un sufijo cuando ya existe. Un proyecto existente nunca se sobrescribe.

El flujo automático:

1. Usa el agente `requisitos` para dividir el objetivo y crear criterios de aceptación.
2. Categoriza cada requisito, por ejemplo como `backend` o `frontend`.
3. Selecciona el agente usando su misión y sus skills; si la respuesta contiene una asignación inválida, el runtime aplica una selección local de respaldo.
4. Agrupa los requisitos por agente.
5. Ejecuta backend y frontend en paralelo durante la fase de implementación. Los requisitos y subagentes de un mismo agente se ejecutan secuencialmente para evitar que dos procesos del mismo especialista modifiquen los mismos archivos simultáneamente.
6. Ejecuta los requisitos de QA en una segunda fase, después de que termine la implementación que deben probar.
7. Comparte el plan completo con cada agente para mantener consistentes contratos como endpoints, campos y respuestas.
8. Guarda la especificación en `proyectos/<nombre>/REQUISITOS.md`, el código en `codigo/backend` y `codigo/frontend`, y el reporte en `RESULTADOS.md`.
9. Consolida resultados, pruebas, archivos modificados y errores.

Las tareas automáticas usan el sandbox `workspace-write`, pero reciben como directorio obligatorio el proyecto aislado. La fase de análisis usa `read-only`. Los agentes tienen prohibido escribir código generado en la raíz del orquestador.

## Autenticación con tu cuenta de ChatGPT

El proveedor predeterminado es `codex`. Reutiliza la autenticación oficial de ChatGPT administrada por Codex CLI, sin guardar una API key en este proyecto.

```bash
./bin/orquesta auth login
./bin/orquesta probar-conexion
./bin/orquesta ejecutar dev-back "Diseñar un endpoint de salud"
```

El runtime busca `codex` en el `PATH` y también dentro de las aplicaciones ChatGPT/Codex para macOS. Si está en otra ubicación, configura `CODEX_BIN`. Puedes elegir un modelo de Codex con `CODEX_MODEL`.

## Proveedor API opcional

Si en otro entorno prefieres una API key, activa explícitamente el proveedor `api`:

```bash
read -s "OPENAI_API_KEY?OpenAI API key: "
export OPENAI_API_KEY
export ORQUESTADOR_PROVIDER="api"
./bin/orquesta probar-conexion
```

Por defecto se usa Responses API. Para un proveedor compatible que solo implemente Chat Completions, configura también `OPENAI_API_STYLE=chat` y su `OPENAI_BASE_URL`.

Después de una ejecución se puede guardar una nota en la memoria del agente:

```bash
python3 runtime/orquestador.py recordar dev-back "El proyecto usa Laravel y PostgreSQL"
python3 runtime/orquestador.py memoria dev-back
```

## Crear agentes desde la terminal

```bash
python3 runtime/orquestador.py crear-agente dev-front \
  --mision "Construir interfaces web accesibles" \
  --skill "Vue 3 y TypeScript" \
  --skill "Pruebas de componentes"
```

Esto crea automáticamente `AGENTE.md`, `memoria.md` y la carpeta `subagentes/`. El nombre debe usar minúsculas, números y guiones.

## Crear subagentes desde la terminal

```bash
python3 runtime/orquestador.py crear-subagente dev-front generador-ui \
  --mision "Implementar componentes y páginas" \
  --skill "Vue 3" \
  --skill "CSS"
```

El comando crea `agentes/dev-front/subagentes/generador-ui.md` y registra el subagente dentro de `AGENTE.md`. `--skill` se puede repetir o dejar fuera para completar las skills posteriormente.

Después puedes comprobar el resultado:

```bash
python3 runtime/orquestador.py listar
python3 runtime/orquestador.py inspeccionar dev-front
python3 runtime/orquestador.py plan dev-front "Crear una página de inicio"
```

Cada Markdown usa encabezados reconocibles (`Nombre`, `Misión`, `Skills`, `Subagentes`, etc.). El runtime valida que exista una misión y que los subagentes referenciados existan.
