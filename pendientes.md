# Estado de Avances y Pendientes — 1 de Septiembre de 2026

Este documento resume el progreso completado en la arquitectura del orquestador distribuido y la hoja de ruta de tareas futuras.

---

## Estado General

El orquestador es una plataforma madura, distribuida y estable. Posee soporte para orquestación multi-módulo en paralelo, recolección de contexto semántico con mTLS, tolerancia a fallos con fallback SQLite, agentes versionados desde Git y ejecución aislada mediante **Pi** y `pi-harness` en máquinas virtuales remotas.

Todos los cambios recientes han sido **verificados al 100% con 9 suites de pruebas automatizadas, committeados y subidos (`push`) a GitHub** en la rama de sincronización (`implementacion_pi` / `prueba_memoria`).

---

## Lo que se completó hoy

### 1. Reorganización Modular del Directorio `tools/`
- Se clasificaron los 27 scripts planos en 7 subcarpetas temáticas especializadas:
  - `tools/orquestacion/`: `orquestar.sh`, `descomponer_requisitos.sh`, `analizar_requisitos.sh`, `clasificar_tarea.sh`, `recolectar_contexto_memoria.sh`, `preparar_proyecto.sh`.
  - `tools/despacho/`: `validar_y_despachar.sh`, `despachar_vm.sh`, `generar_evidencia_agente.sh`, `generar_reporte.sh`, `pi_harness.sh`.
  - `tools/vms/`: `provisionar_vm_pi.sh`, `configurar_perfil_backend_local.sh`, `agregar_repositorio_vm.sh`, `limpiar_vm_pi.sh`, `configurar_ssh_vm.sh`, `probar_vms.sh`, `inicializar_memorias_negocio_vm.sh`.
  - `tools/sincronizacion/`: `sincronizar_agente.sh`, `sincronizar_agente_local.sh`, `instalar_actualizacion_git.sh`, `instalar_monitor_local.sh`, `monitor_agentes_locales.sh`.
  - `tools/gateway/`: `provisionar_memory_gateway.sh`, `configurar_memory_gateway.sh`, `instalar_identidad_gateway.sh`, `memoria_gateway.sh`, **`consultar_memoria.sh`**.
  - `tools/agentes/`: **`crear_agente.sh`**.
  - `tools/remotos/`: bootstraps remotos para las VMs.

### 2. Generador Automatizado de Agentes (`tools/agentes/crear_agente.sh`)
- Permite crear de forma interactiva o no interactiva nuevos agentes/skills en `skills/<nombre>/`.
- Genera automáticamente `SKILL.md` (con frontmatter YAML válido) y la suite completa de subagentes: `subagentes/analista.md`, `subagentes/generador-codigo.md`, `subagentes/qa.md`, `subagentes/documentador.md`.
- Se creó y desplegó el agente `skills/dev-analytics/` (Analítica de Datos y Reportes).

### 3. Explorador y CLI de la Memoria del Gateway (`tools/gateway/consultar_memoria.sh`)
- CLI interactivo para auditar el Memory Gateway sin hacer consultas manuales a SQLite.
- Comandos soportados: `--contratos` (tabla formateada), `--empresa`, `--buscar <termino>`, `--ver <metodo> <ruta>` (esquema JSON formateado con `jq`).

### 4. Selector Dinámico de Agentes en Aprovisionamiento de VMs
- `tools/vms/provisionar_vm_pi.sh` ahora escanea dinámicamente el directorio `skills/` en la Mac.
- Muestra una lista numerada de todos los agentes disponibles y permite asignar cuál habitará la VM durante la configuración.

### 5. Resiliencia y Fallback SQLite en Memory Gateway (`core.mjs`)
- Si Cognee OSS (puerto 8000 en Python) no está disponible o se reinicia, el Memory Gateway en Node.js conmuta automáticamente a un fallback directo en SQLite (`gateway.sqlite`), garantizando **100% de disponibilidad**.

### 6. Pruebas Automatizadas y Ejecución Distribuida en Vivo
- Se ejecutaron las 9 suites de pruebas en `tests/` con **100% de éxito**.
- Se verificó en vivo la orquestación paralela distribuida entre la VM 40 (`backend-comments`) y la VM 231 (`backend-posts`), ambas registrando exitosamente sus nuevos contratos en el Memory Gateway.

---

## Hoja de Ruta / Tareas Pendientes Futuras

### Prioridad Media / Alta
1. **Sincronización de Tecnologías a la Capa Company:** Conectar `.private/tecnologias.json` para publicar automáticamente la pila tecnológica detectada a la capa `company` del Memory Gateway.
2. **Opción `--refrescar-tecnologias`:** Añadir un flag a `tools/vms/agregar_repositorio_vm.sh` para forzar la re-detección de manifiestos cuando se agreguen paquetes al proyecto.
3. **Automatización de VMs para QA y Seguridad:** Añadir soporte de despacho remoto automático para los roles `qa` y `dev-security` (actualmente definidos en `skills/`, pero ejecutados localmente).

### Mejoras a Largo Plazo
4. **Dashboard Web para el Memory Gateway:** Interfaz gráfica web para visualizar el grafo de conocimiento, histórico de contratos y auditoría mTLS.
5. **Mantenimiento Operativo:** Tareas programadas de rotación automática de certificados mTLS de las VMs y backups periódicos de `gateway.sqlite`.
