# Plataforma multiusuario — estado y continuidad

**Fecha de actualización: 7 de septiembre de 2026.**
**Rama activa: `implementacion_usuarios`.**
**Estado: Servidor central desplegado y operativo en VM `192.168.50.30:3100` con Podman, Ollama + Hermes 3 en `127.0.0.1:11434`, y matriz visual de permisos sincronizada con `config/vms.json`.**

Este documento conserva la evidencia de la implementación y los pendientes. Consultar `git status` para conocer el estado actual del árbol de trabajo.

La explicación general y el diagrama están en el [README principal](../README.md). La preparación de cada VM y la matriz de aceptación están en la [guía del piloto](GUIA_PRUEBAS_VM.md).

## 1. Decisiones acordadas

- Usar **exclusivamente Podman** para contenedores, incluido PostgreSQL y las pruebas. No usar Docker Engine ni Docker Compose. Las referencias `docker.io/library/...` de los Containerfiles son nombres de imágenes del registro; el motor que las construye y ejecuta es Podman.
- Arquitectura de los módulos: **VM → contenedor administrado por Podman → repositorio Git del módulo**, con almacenamiento persistente.
- La plataforma será el punto de entrada: inicio de sesión, destinos autorizados, envío de prompts y resultados.
- El servidor central alojará API, PostgreSQL y trabajador del orquestador como servicios separados. Inicialmente pueden compartir servidor.
- Las personas no recibirán claves SSH ni una consola general de la VM. La futura terminal web deberá abrir únicamente el entorno autorizado.
- Acceder a un módulo no concede acceso a los demás módulos de la misma VM.
- Conservar el flujo shell y Pi existente; añadir identidad y autorización alrededor de él.
- El usuario pidió documentar siempre avances y pendientes para poder retomar.

El plan de alcance completo está en [PLAN_PLATAFORMA_MULTIUSUARIO.md](../PLAN_PLATAFORMA_MULTIUSUARIO.md). Este README describe el estado real, que aún no completa todas sus fases.

## 2. Qué quedó implementado

### Correcciones del orquestador

- `tools/orquestacion/analizar_con_llm.py`: resolución por **perfil y repositorio**, en lugar de sobrescribir repositorios con la misma VM; comprobación de categoría, módulo y texto; rechazo explícito de destinos desconocidos y respuestas parcialmente válidas.
- `tools/orquestacion/analizar_requisitos.sh`: propaga el rechazo explícito del analista y conserva requisitos generales originales al utilizar el LLM.
- `tools/despacho/validar_y_despachar.sh`: sustituye la comprobación seguida de `touch` por un candado de directorio creado mediante `mkdir` atómico. Sigue bloqueando candados antiguos de archivo.
- `tests/probar_analista_llm.py`: cinco pruebas aisladas, sin Ollama.
- `tests/probar_automatizacion.sh`: comprueba la sintaxis de cada shell script, incorpora las pruebas del LLM y desactiva Ollama para que la suite determinista no dependa de un servicio local.

**No se corrigieron todavía el manejo Git del despachador SSH antiguo ni su publicación de PR.**

### API y PostgreSQL

Código en `plataforma/src/`, con Node 24, TypeScript, Fastify y PostgreSQL. Dependencias instaladas y `package-lock.json` generado.

- Migración inicial con usuarios, sesiones, VMs, administradores por VM, destinos, permisos, trabajos y auditoría.
- Inicio/cierre de sesión y cambio de contraseña. Contraseñas derivadas con `scrypt` de Node; tokens de sesión aleatorios almacenados como hash en PostgreSQL.
- Cookies `HttpOnly`, `SameSite=Strict`, expiración y atributo `Secure` con origen HTTPS.
- Comprobación de origen en operaciones de escritura, validación de solicitudes y límite persistente de intentos de inicio de sesión.
- Administrador global inicial mediante CLI; administradores delegados por VM y operadores.
- Altas de usuarios, VMs y destinos; asignación de administración por VM y permisos de lectura/escritura por destino.
- Los administradores no reciben permiso implícito para ejecutar tareas: también necesitan una asignación de módulo.
- Las consultas de destinos y trabajos respetan el usuario y los permisos vigentes.
- Desactivar una cuenta elimina sus sesiones; revocar permisos cancela trabajos pendientes y solicita cancelación de los activos.

**Diferencia respecto al plan:** esta primera versión usa autenticación local con contraseña, no OIDC. No incluye recuperación de contraseña, MFA ni integración con un proveedor de identidad. No asumir que esas funciones existen.

### Cola y trabajador

- Reserva transaccional de trabajos con PostgreSQL y exclusión de ejecuciones simultáneas sobre el mismo destino.
- Clave de idempotencia por usuario para evitar duplicados de solicitudes.
- Revalidación de permisos antes del despacho y durante los latidos.
- Una ejecución que pierde contacto queda en `reconciliation_required`; no se reintenta automáticamente.
- La cancelación de una ejecución activa no se presenta como detención remota confirmada.
- `driver.ts` genera un inventario temporal limitado al destino y llama a `tools/orquestacion/orquestar.sh` con un adaptador de despacho Podman.
- El registro de conexiones es un archivo administrativo independiente; la API no acepta rutas de claves ni comandos arbitrarios del navegador.
- El trabajador mantiene **desactivados el LLM y el Memory Gateway** en este primer flujo y utiliza inventario tecnológico vacío, para no mezclar contexto global privado con cuentas de usuarios. Restaurar esas capacidades requiere autorización del contexto por módulo.
- La primera API crea un trabajo para un destino elegido. Todavía no implementa una solicitud web repartida entre múltiples destinos autorizados.

### Adaptador y ejecutor remoto — escritos, sin validación de extremo a extremo

- `bin/despachar_podman.sh`: adaptador interno del orquestador; SSH con host conocido, identidad explícita y sin reenvío de agente. Envía una solicitud JSON a un comando fijo.
- `remoto/ejecutor_podman.sh`: diseño de comando forzado de SSH, registro de destinos, comprobaciones mínimas del contenedor, candado por módulo y registro por trabajo.
- `remoto/ejecutar_tarea.sh`: copia Git independiente por tarea, ejecución de Pi mediante pi-harness, política de lectura y evidencia.
- `config/worker.example.json` y `config/remoto.example.json`: ejemplos **deshabilitados**. No apuntan a una VM real.
- La ejecución propuesta no hace `git push` ni crea PR. Los cambios quedarían en su copia por tarea, pendiente de una fase de publicación autorizada.

**No se instalaron estos scripts en ninguna VM ni se ejecutó Pi dentro de Podman.**

### Interfaz web y administración

- Vue 3 con inicio de sesión, cambio de contraseña, destinos asignados, envío de prompts, historial, detalle y cancelación de trabajos.
- Administración de usuarios, VMs, módulos, asignaciones de lectura/escritura y administradores delegados; listado de permisos, revocación de administradores y desactivación de destinos.
- Los módulos nuevos quedan con `execution_ready=false`: no aceptan trabajos hasta completar su preparación. No hay todavía un procedimiento implementado para aprobar esa preparación; no habilitarla manualmente sin el piloto.
- Auditoría de cambios con detalles y límite inicial de trabajos pendientes por usuario. Falta revisar cuotas bajo concurrencia y retención.
- Adaptador corregido para conservar la política de solo lectura detectada por el analista.
- Integración WebMCP opcional por detección de capacidades, sin verificación en un navegador compatible.

### Contenedores del servidor

- `Containerfile`: imagen API/web/trabajador con TypeScript compilado, recursos Vue y usuario sin privilegios.
- `bin/iniciar_podman.sh` ejecutado correctamente: pod `orquestador-plataforma`, PostgreSQL persistente y API en **http://127.0.0.1:3100**. PostgreSQL no tiene puerto publicado independiente.
- Migraciones con usuario propietario; API con usuario PostgreSQL separado `orquestador_app`, sin acceso a migraciones ni creación de esquema.
- Actualización de API mediante reemplazo de contenedor y comprobación de salud con intento de recuperación de la imagen anterior. Falta ensayar actualización y fallo de salud deliberado.
- `bin/probar_podman.sh` verificado de principio a fin, con PostgreSQL efímero y limpieza.
- `.containerignore` y `.gitignore` excluyen credenciales y artefactos locales.

### Imagen de módulo y bloqueo encontrado

`Containerfile.modulo` construye una imagen base frontend con Pi 0.85.1, pi-harness, Bubblewrap y agente inmutable. Para backend faltan PHP/Composer y las dependencias correspondientes.

`bin/probar_aislamiento_podman.sh` construyó la imagen y comprobó escritura del volumen propio, raíz de solo lectura y ausencia de sockets. El diagnóstico del harness encontró los binarios, pero la prueba **real** de Bubblewrap falló:

```text
bwrap: Can't mount proc on /newroot/proc: Operation not permitted
```

El script devuelve 4 y limpia sus recursos temporales. La causa precisa de la restricción del host todavía requiere diagnóstico. No usar modo privilegiado ni desactivar protecciones como atajo. El ejecutor remoto ahora también realiza esta comprobación antes de registrar o ejecutar una tarea. **No se ejecutó Pi ni se habilitó ninguna VM.**

## 3. Qué se verificó realmente

| Comprobación | Resultado |
|---|---|
| Analista LLM | 5 pruebas pasaron |
| Candado shell | 12 invocaciones concurrentes, una sola ejecución; candado antiguo respetado |
| `npm run build` | API TypeScript y frontend Vite compilaron |
| `bin/probar_podman.sh` | 19 pruebas de API/cola pasaron con PostgreSQL real |
| Arranque Podman de API/PostgreSQL | Correcto, imagen `localhost/orquestador-plataforma:0.1` |
| HTTP real | Inicio, recursos estáticos, sesión administradora y logout verificados |
| Imagen de módulo | Construcción correcta; Bubblewrap anidado falló |
| Suite general | Scripts shell y extensión Pi pasaron; falla `tests/probar_memory_gateway.mjs:137` con «el administrador no pudo visualizar el grafo» |
| Visualizador Python | Pendiente en esta ejecución: la suite se detuvo antes |
| Navegador | Sin pruebas visuales/DOM; validación web por HTTP |
| Trabajador → SSH → Podman → Pi | Pendiente |

Se corrigieron respuestas simuladas obsoletas del provisionador y pruebas de memoria que dependían de la base privada real. `consultar_memoria.sh` permite indicar una base de prueba, abre SQLite en solo lectura y escapa literales SQL. En Linux se prueba el rechazo del instalador exclusivo de macOS; no se verificó LaunchAgent real.

La suite general requiere permitir servidores de prueba locales: dentro del aislamiento de Codex falla `listen EPERM`; ejecutada con autorización fuera de él alcanza el fallo de grafos descrito. No afirmar que la suite completa pasa.

## 4. Estado del entorno

- API y PostgreSQL permanecen activos en Podman rootless, accesibles únicamente por localhost.
- Cuenta administradora inicial: **carlos@pull.srl**. Contraseña generada guardada localmente en `.private/plataforma/acceso-inicial.txt` con modo 600. No copiarla a documentación, chat o Git. Cambiarla desde la plataforma después del primer ingreso; retirar el archivo cuando ya no se necesite.
- `.private/plataforma/` contiene credenciales privadas del servidor; no eliminarlas para reiniciar. La base persiste en el volumen `orquestador-postgres`.
- El trabajador no está iniciado. Los registros de ejemplo siguen deshabilitados. No se modificó `config/vms.json` ni las VMs existentes.
- No se realizó despliegue público durante la implementación descrita. Consultar Git para el estado actual de commits.
- Node del sistema es 18; se usó Node 24 del runtime de Codex. jq se extrajo temporalmente; instalarlo de forma estable para uso desde el host.

Rutas de esta sesión (no portables):

```bash
export PATH="/home/talitos/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin:/tmp/prueba-agentes-deps/root/usr/bin:$PATH"
export LD_LIBRARY_PATH="/tmp/prueba-agentes-deps/root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

Requisitos del host: Node 24+, jq, Git, OpenSSH, OpenSSL y Podman. No depender de `/tmp` permanentemente.

### VM nueva pendiente de acceso

El usuario creó la VM `192.168.1.119` con acceso inicial `root`. Se comprobó que SSH responde y que el cliente ofrece la llave creada, pero la VM la rechaza. Cambiar la contraseña no resolvió el acceso. Está pendiente revisar desde la consola remota los permisos y contenido de `authorized_keys`, la configuración efectiva y los registros de SSH. No se ha instalado Podman ni ejecutado el piloto en esa VM desde esta sesión.

## 5. Pendientes para continuar, en orden

### A. Cerrar las comprobaciones pendientes

1. Revisar el diff completo, incluidos los archivos nuevos de `plataforma/`.
2. Diagnosticar la regresión de visualización de grafos en `tests/probar_memory_gateway.mjs:137`, ejecutar esa suite y el visualizador Python; después completar la suite general.
3. Ensayar actualización y recuperación de la API conservando usuarios y datos.
4. Añadir comprobación de tipos de las plantillas Vue y revisión visual autorizada de los flujos administrativos.

### B. Completar el ejecutor remoto antes de habilitarlo

1. Completar y validar la imagen de módulo: existe `Containerfile.modulo` para frontend; falta backend con PHP/Composer.
2. Provisionar una VM de laboratorio con dos volúmenes y dos contenedores separados. Instalar el registro y el comando forzado de SSH bajo control administrativo.
3. Validar Bubblewrap dentro de Podman. Si falla, no usar contenedores privilegiados ni eliminar el aislamiento como atajo.
4. Contrastar los campos de `podman inspect` con la versión instalada, especialmente capacidades y montajes. Las comprobaciones remotas fueron escritas pero aún no se probaron contra un contenedor real.
5. Validar que el agente no alcanza otro repositorio, el host, sockets de Podman ni credenciales administrativas.
6. Diseñar e instalar credenciales de Pi limitadas y memoria local del módulo sin ampliar los montajes autorizados accidentalmente.
7. Probar el adaptador con dobles de SSH/Podman y después el flujo completo real. Confirmar límites de solicitud/salida, timeout, señales y persistencia de evidencia.
8. Implementar consulta de estado y cancelación remota confirmada. Actualmente el timeout limita la ejecución, pero cortar SSH no demuestra que Pi se haya detenido.
9. Implementar una operación administrativa auditada para resolver `reconciliation_required` tras comprobar el remoto. Actualmente ese estado bloquea nuevas ejecuciones del destino y no hay API de conciliación.
10. Verificar el apagado del trabajador y la carrera entre revocación, despacho y recepción de resultados. Revisar orden de locks de usuario/destino/trabajo para evitar deadlocks bajo concurrencia.

### C. Aislamiento Git y publicación

1. Probar el clon por tarea del nuevo ejecutor: referencia base, repositorios privados, dependencias, cambios previos, concurrencia y conservación de resultados.
2. Corregir el despachador antiguo: todavía usa `checkout -B` tolerando errores y `git add -A` sobre el workspace existente.
3. Añadir permiso separado para publicación; revalidarlo inmediatamente antes del push y de crear el PR.
4. Diferenciar rama publicada, PR creado y enlace de comparación. El flujo antiguo todavía puede presentar un enlace `/compare/` como PR.

### D. Administración y seguridad del servidor

1. Decidir si mantener autenticación local o integrar OIDC. Completar recuperación de cuenta y, si corresponde, MFA.
2. Completar edición y ciclo de vida de VMs/destinos y procedimiento de preparación; la asignación/revocación de administradores y listado de permisos ya están implementados.
3. Completar auditoría con datos suficientes para identificar el destinatario y cambio de cada asignación, sin registrar contraseñas ni prompts privados innecesarios.
4. Añadir cuotas de trabajos, límites de retención y limpieza de sesiones, intentos de login, evidencia y copias de trabajo.
5. Ensayar respaldos/restauración preservando los roles separados de migración y ejecución ya implementados.
6. Añadir HTTPS/reverse proxy, copia de seguridad, restauración y arranque persistente con Podman/Quadlet o systemd. El arranque actual es local y manual.

### E. Memoria, plataforma web y ampliación

1. Filtrar tecnologías, contratos y memoria por permisos antes de reactivar el Gateway y el LLM en el trabajador. El inventario global actual no puede exponerse a todos los usuarios.
2. Ampliar la autorización del Gateway a repositorios/módulos cuando sus permisos por core/tenant sean demasiado amplios.
3. Validar visualmente la interfaz implementada y completar el flujo con resultados de una ejecución Pi real.
4. Añadir solicitudes con varios destinos autorizados manteniendo resultados y permisos independientes.
5. Implementar la terminal web restringida después de validar el flujo de prompts; hoy no existe permiso operativo ni servicio de terminal.
6. Actualizar `AGENTS.md` y los apartados anteriores del README principal: aún hay contradicciones sobre Python y soporte completo de QA/security. El piloto nuevo solo admite backend/frontend.

## 6. Comandos para retomar

Desde la raíz del repositorio, usando Node 24 y jq disponibles:

```bash
git status --short
git diff --check
python3 tests/probar_analista_llm.py
npm ci --prefix plataforma --ignore-scripts
npm run build --prefix plataforma
bash plataforma/bin/probar_podman.sh
```

Para iniciar o actualizar el servidor local existente:

```bash
bash plataforma/bin/iniciar_podman.sh
```

Ese comando crea servicios locales y credenciales privadas. No inicia el trabajador ni habilita ninguna VM remota automáticamente. Para el administrador inicial, la CLI recibe correo mediante `ADMIN_EMAIL` y contraseña por entrada estándar; no incluir contraseñas en argumentos ni archivos versionados.

Las operaciones de escritura de la API requieren `Origin` igual a `APP_ORIGIN`, incluso desde un cliente de pruebas. Las sesiones usan cookies, no tokens entregados en el cuerpo de la respuesta.

## 7. Mapa rápido de archivos

| Archivo | Responsabilidad |
|---|---|
| `src/api.ts` | Sesiones, administración, permisos y trabajos |
| `src/auth.ts` | Derivación de contraseñas y tokens |
| `src/db.ts` / `migrations/001_inicial.sql` | Base de datos y migraciones |
| `src/cli.ts` | Migraciones y administrador inicial |
| `src/queue.ts` | Reserva, latido, revocación y conciliación |
| `src/driver.ts` / `src/worker-main.ts` | Puente hacia el orquestador shell |
| `bin/despachar_podman.sh` | Adaptador de despacho por SSH restringido |
| `remoto/*.sh` | Ejecutor de VM y ejecución dentro del módulo |
| `config/*.example.json` | Registros administrativos de ejemplo, deshabilitados |
| `Containerfile` / `bin/iniciar_podman.sh` | Imagen y arranque local de API/PostgreSQL |
| `tests/api.test.ts` / `bin/probar_podman.sh` | Pruebas de backend con PostgreSQL en Podman |

**Siguiente paso recomendado:** diagnosticar Bubblewrap en una VM de laboratorio, comprobar dos módulos aislados y el flujo SSH/Pi antes de habilitar ejecución. En paralelo, resolver el fallo de grafos de la suite antigua.
