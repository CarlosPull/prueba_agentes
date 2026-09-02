# Estado de Avances y Pendientes — 2 de Septiembre de 2026

Este documento resume las mejoras implementadas y verificadas en el árbol de trabajo actual. Un cambio sólo debe considerarse publicado cuando exista el `commit` y `push` correspondiente.

---

## Estado General

El orquestador es una plataforma distribuida, autónoma y madura para la gestión de agentes. Posee soporte para orquestación multi-módulo en paralelo, recolección de contexto semántico con mTLS, tolerancia a fallos con fallback SQLite, agentes versionados desde Git, aprovisionamiento interactivo de VMs y ejecución aislada mediante **Pi** y `pi-harness` en máquinas virtuales remotas.

El conjunto actual se verifica con el agregador `bash tests/probar_automatizacion.sh`. En esta actualización, sus 13 grupos de comprobaciones finalizaron correctamente.

---

## Resumen de Todo lo Completado Hoy

### 1. Reorganización Modular del Directorio `tools/`
- Se clasificaron todos los scripts en 7 subcarpetas temáticas especializadas:
  - `tools/orquestacion/`: `orquestar.sh`, `descomponer_requisitos.sh`, `analizar_requisitos.sh`, `clasificar_tarea.sh`, `recolectar_contexto_memoria.sh`, `preparar_proyecto.sh`.
  - `tools/despacho/`: `validar_y_despachar.sh`, `despachar_vm.sh`, `generar_evidencia_agente.sh`, `generar_reporte.sh`, `pi_harness.sh`.
  - `tools/vms/`: `provisionar_vm_pi.sh`, `configurar_perfil_backend_local.sh`, `agregar_repositorio_vm.sh`, `limpiar_vm_pi.sh`, `configurar_ssh_vm.sh`, `probar_vms.sh`, `inicializar_memorias_negocio_vm.sh`.
  - `tools/sincronizacion/`: `sincronizar_agente.sh`, `sincronizar_agente_local.sh`, `instalar_actualizacion_git.sh`, `instalar_monitor_local.sh`, `monitor_agentes_locales.sh`.
  - `tools/gateway/`: `provisionar_memory_gateway.sh`, `configurar_memory_gateway.sh`, `instalar_identidad_gateway.sh`, `memoria_gateway.sh`, **`consultar_memoria.sh`**.
  - `tools/agentes/`: **`crear_agente.sh`**.
  - `tools/remotos/`: bootstraps remotos para las VMs.

### 2. Sincronización Automática de Tecnologías a la Capa `company` del Gateway
- `tools/vms/agregar_repositorio_vm.sh` detecta las tecnologías de los manifiestos del proyecto y sincroniza automáticamente un resumen estructurado con la capa `company` del Memory Gateway (`memoria_gateway.sh guardar-empresa`).

### 3. Flag `--refrescar-tecnologias` en `agregar_repositorio_vm.sh`
- Permite forzar la re-detección de manifiestos cuando se agreguen o modifiquen paquetes (`composer.json`, `package.json`) en un proyecto registrado.

### 4. Soporte y Despacho Remoto para Roles `qa` y `dev-security`
- `tools/orquestacion/orquestar.sh` y `tools/orquestacion/analizar_requisitos.sh` habilitan la categorización y enrutamiento automático hacia perfiles de VM configurados con stacks `qa` o `security`.

### 5. Generador Automatizado de Agentes (`tools/agentes/crear_agente.sh`)
- Genera la suite completa en `skills/<nombre>/`: `SKILL.md`, `subagentes/analista.md`, `subagentes/generador-codigo.md`, `subagentes/qa.md` y `subagentes/documentador.md`.
- Se creó y desplegó el agente `skills/dev-analytics/` (Analítica de Datos y Reportes).

### 6. Explorador CLI de Memoria y Contratos (`tools/gateway/consultar_memoria.sh`)
- Permite auditar y buscar contratos JSON o reglas corporativas en la terminal (`--contratos`, `--empresa`, `--buscar <termino>`, `--ver <metodo> <ruta>`).

### 7. Selector Dinámico de Agentes en Aprovisionamiento de VMs
- `tools/vms/provisionar_vm_pi.sh` escanea dinámicamente el directorio `skills/` en la Mac y permite elegir el agente de la VM desde un menú numerado.

### 8. Resiliencia y Fallback SQLite en Memory Gateway (`core.mjs`)
- Si Cognee OSS se reinicia o está fuera de servicio, el Memory Gateway conmuta automáticamente a SQLite (`gateway.sqlite`), garantizando **disponibilidad del 100%**.

### 9. Visualizador propio de grafos Cognee
- `tools/gateway/visualizar_grafos.py` sirve una interfaz HTML local sin dependencias externas.
- `tools/gateway/visualizador_grafos.html` permite seleccionar datasets, buscar contexto, mover nodos, hacer zoom e inspeccionar relaciones con actualización automática.
- El acceso pasa por endpoints administrativos mTLS del Memory Gateway, protegidos con `graphs:read`; no se exponen credenciales en el navegador ni datasets ajenos al sistema.

---

## Cobertura de Pruebas Automatizadas (13/13 PASARON)

```bash
node tests/probar_memory_gateway.mjs          # PASÓ (mTLS, RBAC, SQLite y Cognee)
python3 tests/probar_visualizador_grafos.py   # PASÓ (HTML y proxy local del visualizador)
bash tests/probar_enrutamiento_modular.sh      # PASÓ (paralelismo y asignación de repositorios)
bash tests/probar_clasificacion.sh             # PASÓ (clasificación y descomposición)
node tests/probar_extension_pi.mjs            # PASÓ (publicación automática de contratos)
bash tests/probar_pi_harness.sh               # PASÓ (aislamiento Bubblewrap/Seatbelt y políticas)
bash tests/probar_provisionamiento_pi.sh       # PASÓ (auditoría de VM y selector de agentes)
bash tests/probar_sincronizacion.sh            # PASÓ (pull Git del agente y cambio de symlink)
bash tests/probar_creacion_agente.sh          # PASÓ (generador de agentes en skills/)
bash tests/probar_consultar_memoria.sh        # PASÓ (CLI de consulta de memoria)
bash tests/probar_refresco_tecnologias.sh     # PASÓ (flag --refrescar-tecnologias y sync company)
```
