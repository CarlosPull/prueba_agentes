#!/usr/bin/env bash
# Runner ultraliviano para orquestar ejecuciones de Agent Runner hacia VMs remotas.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIR="$ROOT/skills"
PROJECTS_DIR="$ROOT/proyectos"


# Configuración de VMs (por defecto o sobreescribibles con variables de entorno)
VM_BACKEND_IP="${ORQUESTADOR_VM_BACKEND_IP:-192.168.50.193}"
VM_FRONTEND_IP="${ORQUESTADOR_VM_FRONTEND_IP:-192.168.50.40}"
VM_USER="${ORQUESTADOR_VM_USER:-serveradmin}"
VM_BACKEND_REPO="${ORQUESTADOR_VM_BACKEND_REPO:-/home/serveradmin/laravel-dev}"
VM_FRONTEND_REPO="${ORQUESTADOR_VM_FRONTEND_REPO:-/home/serveradmin/vue-dev}"
VM_RUNNER_BIN="${ORQUESTADOR_VM_AGENT_RUNNER_BIN:-/home/serveradmin/.local/bin/agent-runner}"

PROBAR_VMS() {
  echo "🔍 Diagnosticando conectividad SSH y Agent Runner en las VMs..."
  echo "------------------------------------------------------------"
  
  echo -n "1. VM Backend ($VM_USER@$VM_BACKEND_IP)... "
  if ssh -o ConnectTimeout=5 -o BatchMode=yes "$VM_USER@$VM_BACKEND_IP" "echo OK" >/dev/null 2>&1; then
    echo "✓ SSH OK"
  else
    echo "❌ Fallo de conexión SSH"
  fi

  echo -n "2. VM Frontend ($VM_USER@$VM_FRONTEND_IP)... "
  if ssh -o ConnectTimeout=5 -o BatchMode=yes "$VM_USER@$VM_FRONTEND_IP" "echo OK" >/dev/null 2>&1; then
    echo "✓ SSH OK"
  else
    echo "❌ Fallo de conexión SSH"
  fi
  echo "------------------------------------------------------------"
}

if [ "${1:-}" = "probar-vms" ]; then
  PROBAR_VMS
  exit 0
fi

TAREA="${1:-}"
if [ -z "$TAREA" ]; then
  echo "Uso: ./bin/orquestar_vms.sh \"Descripción de la tarea u objetivo\""
  echo "     ./bin/orquestar_vms.sh probar-vms"
  exit 1
fi

# 1. Crear la carpeta del proyecto
SLUG=$(echo "$TAREA" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/^-//' -e 's/-$//' | cut -c 1-50)
SLUG="${SLUG:-proyecto}"
PROJECT_DIR="$PROJECTS_DIR/$SLUG"
mkdir -p "$PROJECT_DIR"

echo "# Solicitud original" > "$PROJECT_DIR/SOLICITUD.md"
echo "" >> "$PROJECT_DIR/SOLICITUD.md"
echo "$TAREA" >> "$PROJECT_DIR/SOLICITUD.md"

# 2. Cargar las instrucciones desde la carpeta skills/ de cada rol
DEV_BACK_MD="$SKILLS_DIR/dev-back/SKILL.md"
[ ! -f "$DEV_BACK_MD" ] && DEV_BACK_MD="$SKILLS_DIR/dev-back/AGENTE.md"

DEV_FRONT_MD="$SKILLS_DIR/dev-front/SKILL.md"
[ ! -f "$DEV_FRONT_MD" ] && DEV_FRONT_MD="$SKILLS_DIR/dev-front/AGENTE.md"

PROMPT_BACK="Tarea: $TAREA"
if [ -f "$DEV_BACK_MD" ]; then
  PROMPT_BACK="$(cat "$DEV_BACK_MD")

---
REQUISITO O TAREA DE BACKEND:
$TAREA"
fi

PROMPT_FRONT="Tarea: $TAREA"
if [ -f "$DEV_FRONT_MD" ]; then
  PROMPT_FRONT="$(cat "$DEV_FRONT_MD")

---
REQUISITO O TAREA DE FRONTEND:
$TAREA"
fi


# Variables de entorno e inyección de PATH para las VMs remotas
ENV_EXPORTS="export PATH=\$PATH:/home/serveradmin/.nvm/versions/node/v24.19.0/bin:/home/serveradmin/.local/bin;"
if [ -n "${OPENAI_API_KEY:-}" ]; then
  ENV_EXPORTS="export OPENAI_API_KEY='$OPENAI_API_KEY'; $ENV_EXPORTS"
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  ENV_EXPORTS="export ANTHROPIC_API_KEY='$ANTHROPIC_API_KEY'; $ENV_EXPORTS"
fi

LOG_BACK="$PROJECT_DIR/backend_output.log"
LOG_FRONT="$PROJECT_DIR/frontend_output.log"

echo "============================================================"
echo "🚀 Orquestando tarea distribuida hacia las VMs"
echo "Proyecto: $PROJECT_DIR"
echo "Objetivo: $TAREA"
echo "============================================================"

# 3. Despachar ejecuciones paralelas en ambas VMs
echo "▶️ Despachando a la VM Backend ($VM_BACKEND_IP)..."
ssh -o ConnectTimeout=10 "$VM_USER@$VM_BACKEND_IP" \
  "$ENV_EXPORTS $VM_RUNNER_BIN start --agent opencode --role backend --workspace $VM_BACKEND_REPO --backend auto --task '$PROMPT_BACK'" \
  > "$LOG_BACK" 2>&1 &
PID_BACK=$!

echo "▶️ Despachando a la VM Frontend ($VM_FRONTEND_IP)..."
ssh -o ConnectTimeout=10 "$VM_USER@$VM_FRONTEND_IP" \
  "$ENV_EXPORTS $VM_RUNNER_BIN start --agent opencode --role frontend --workspace $VM_FRONTEND_REPO --backend auto --task '$PROMPT_FRONT'" \
  > "$LOG_FRONT" 2>&1 &
PID_FRONT=$!

echo "⌛ Esperando que finalicen las ejecuciones paralelas en ambas VMs..."
STATUS_BACK=0
STATUS_FRONT=0

wait $PID_BACK || STATUS_BACK=$?
wait $PID_FRONT || STATUS_FRONT=$?

# 4. Generar el informe final AGENT_RUNNER.md
REPORT="$PROJECT_DIR/AGENT_RUNNER.md"
{
  echo "# Informe de Ejecución de Agent Runner"
  echo ""
  echo "Fecha: $(date)"
  echo "Objetivo: $TAREA"
  echo ""
  echo "## Backend (VM: $VM_BACKEND_IP)"
  echo "- Estado: $( [ $STATUS_BACK -eq 0 ] && echo "✓ Completado con éxito" || echo "❌ Error (Código: $STATUS_BACK)" )"
  echo "- Workspace: \`$VM_BACKEND_REPO\`"
  echo ""
  echo "\`\`\`text"
  cat "$LOG_BACK"
  echo "\`\`\`"
  echo ""
  echo "## Frontend (VM: $VM_FRONTEND_IP)"
  echo "- Estado: $( [ $STATUS_FRONT -eq 0 ] && echo "✓ Completado con éxito" || echo "❌ Error (Código: $STATUS_FRONT)" )"
  echo "- Workspace: \`$VM_FRONTEND_REPO\`"
  echo ""
  echo "\`\`\`text"
  cat "$LOG_FRONT"
  echo "\`\`\`"
} > "$REPORT"

echo "------------------------------------------------------------"
echo "✅ Ejecución finalizada."
echo "📄 Reporte consolidado guardado en: $REPORT"
