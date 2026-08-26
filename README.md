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
/preview <objetivo>
/requirements <objetivo>
/orchestrate <objetivo>   # requisitos + Agent Runner
/build <objetivo>         # ejecutores internos heredados
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

Para previsualizar el prompt de análisis sin enviarlo al modelo:

```bash
./bin/orquesta orquestar "Genera un login" --proyecto revision-login
```

Este comando muestra y guarda el prompt de análisis, pero no lo envía. Para aprobar explícitamente el envío, obtener los requisitos y detenerse antes de Agent Runner:

```bash
./bin/orquesta orquestar "Genera un login" --proyecto revision-login --confirmar --solo-plan
```

Sin `--solo-plan`, después de guardar `REQUISITOS.md` el orquestador agrupa los requisitos backend
y frontend y los despacha a `/Users/carlos/Documents/GitHub/agent-runner`. Antes de cada proceso
muestra el prompt compuesto completo y vuelve a pedir aprobación. Backend y frontend se ejecutan
en paralelo dentro de `codigo/backend` y `codigo/frontend`.

```bash
./bin/orquesta orquestar "Genera un login" --confirmar
```

Puedes indicar un nombre explícito para el proyecto:

```bash
./bin/orquesta orquestar "Genera un login" --proyecto sistema-login --confirmar
```

Si la vista previa tiene un nombre explícito, puedes repetir exactamente el comando agregando
`--confirmar`: el runtime reutiliza esa carpeta solamente cuando sigue vacía, conserva la misma
solicitud y aún no tiene requisitos, resultados ni código. Cualquier otro proyecto existente se
rechaza para evitar sobrescrituras. Si no indicas `--proyecto`, se genera un nombre desde el prompt
y se añade un sufijo cuando ya existe.

El flujo automático:

1. Usa el agente `requisitos` para dividir el objetivo y crear criterios de aceptación.
2. Categoriza cada requisito, por ejemplo como `backend` o `frontend`.
3. Selecciona el agente usando su misión y sus skills; si la respuesta contiene una asignación inválida, el runtime aplica una selección local de respaldo.
4. Guarda la especificación categorizada en `proyectos/<nombre>/REQUISITOS.md`.
5. Agrupa todos los requisitos backend en una tarea y todos los frontend en otra.
6. Muestra el prompt compuesto de cada rol y solicita una aprobación independiente.
7. Ejecuta los dos comandos de Agent Runner en paralelo cuando ambos roles existen.
8. Limita backend a `codigo/backend` y frontend a `codigo/frontend` mediante las políticas del runner.
9. Guarda manifiestos en `AGENT_RUNNER_RUNS/` y el resumen en `AGENT_RUNNER.md`.

La fase de análisis usa `read-only`. La implementación usa el sandbox de sistema operativo de
Agent Runner (`seatbelt` en macOS o `bwrap` en Linux), además de un workspace separado por rol.
Los ejecutores internos anteriores siguen disponibles únicamente con `--ejecutar`.

## Barrera de revisión de prompts

Ningún prompt generado por `orquestar` se envía automáticamente. Sin `--confirmar`, el runtime:

1. Crea el proyecto y guarda la solicitud original.
2. Muestra en terminal el contenido exacto que el orquestador intentaría enviar.
3. Lo guarda en `proyectos/<nombre>/PROMPTS/` con estado `previsualizado-no-enviado`.
4. Detiene el flujo antes de invocar Codex o la API.

Con `--confirmar`, cada llamada muestra nuevamente proveedor, sandbox, directorio y prompt completo, y solicita:

```text
¿Enviar exactamente este prompt a la IA? [s/N]:
```

Solo una respuesta afirmativa envía esa llamada. Esto también se aplica individualmente a cada agente y subagente durante la ejecución paralela. Los archivos auditables cambian a `aprobado-para-envio` o `rechazado-no-enviado` según la decisión.

## Integración con Agent Runner

El ejecutable predeterminado es:

```text
/Users/carlos/Documents/GitHub/agent-runner/.venv/bin/agent-runner
```

Puede cambiarse con `AGENT_RUNNER_BIN` o `AGENT_RUNNER_ROOT`. El orquestador añade al `PATH` el
Codex incluido en ChatGPT, reutiliza la autenticación existente y guarda los manifiestos del runner
en `proyectos/<nombre>/AGENT_RUNNER_RUNS/`. El resumen de despachos queda en `AGENT_RUNNER.md`.
Agent Runner actualmente solo incluye políticas `backend` y `frontend`; cualquier requisito de otra
categoría se registra como omitido.

### Perfil de repositorios Laravel + Vue

Para trabajar directamente y en paralelo sobre los repositorios existentes:

```text
backend  → /Users/carlos/Documents/GitHub/laravel-dev
frontend → /Users/carlos/Documents/GitHub/vue-dev
```

usa:

```bash
./bin/orquesta orquestar \
  "Implementa el módulo solicitado y define un contrato API compartido" \
  --proyecto modulo-ejemplo \
  --repos-dev \
  --confirmar
```

El análisis recibe las tecnologías y rutas de ambos repositorios. Después, Agent Runner ejecuta
`dev-back` sobre `laravel-dev` y `dev-front` sobre `vue-dev` en paralelo. Cada prompt incluye la
misión, skills, memoria y responsabilidades de subagentes del agente correspondiente. Las rutas se
pueden cambiar con `ORQUESTADOR_BACKEND_REPO` y `ORQUESTADOR_FRONTEND_REPO`.

Para revisar únicamente los requisitos categorizados antes de tocar esos repositorios:

```bash
./bin/orquesta orquestar \
  "Implementa el módulo solicitado" \
  --proyecto revision-modulo \
  --repos-dev \
  --confirmar \
  --solo-plan
```

### Perfil distribuido en Máquinas Virtuales (VM5 + VM6)

Para despachar ejecuciones de Agent Runner hacia máquinas virtuales aisladas en tu red:

```text
backend  → VM5 (192.168.50.193 / serveradmin@192.168.50.193:/home/serveradmin/laravel-dev)
frontend → VM6 (192.168.50.40  / serveradmin@192.168.50.40:/home/serveradmin/vue-dev)
```

1. Diagnóstico de conectividad SSH, repositorios y Agent Runner en ambas VMs:

```bash
./bin/orquesta probar-vms
```

2. Ejecución distribuida en paralelo hacia las VMs:

```bash
./bin/orquesta orquestar \
  "Implementa el módulo solicitado en las VMs" \
  --proyecto modulo-vms \
  --vms \
  --confirmar
```

Las IPs, usuarios y rutas se pueden reconfigurar mediante las variables de entorno:
- `ORQUESTADOR_VM_BACKEND_IP` (defecto: `192.168.50.193`)
- `ORQUESTADOR_VM_FRONTEND_IP` (defecto: `192.168.50.40`)
- `ORQUESTADOR_VM_USER` (defecto: `serveradmin`)
- `ORQUESTADOR_VM_BACKEND_REPO` (defecto: `/home/serveradmin/laravel-dev`)
- `ORQUESTADOR_VM_FRONTEND_REPO` (defecto: `/home/serveradmin/vue-dev`)
- `ORQUESTADOR_VM_AGENT_RUNNER_BIN` (defecto: `/home/serveradmin/.local/bin/agent-runner`)

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
