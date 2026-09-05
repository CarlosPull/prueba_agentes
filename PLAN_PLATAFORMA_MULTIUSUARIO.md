# Plan de plataforma multiusuario con ejecución por módulo

Fecha: 5 de septiembre de 2026.
Estado: propuesta de implementación; este documento no modifica la ejecución actual.

## Objetivo y alcance acordado

Convertir el orquestador en una plataforma donde las personas inicien sesión, envíen solicitudes y consulten resultados exclusivamente sobre las máquinas y módulos asignados. Conservar el análisis de requisitos, los agentes Pi, el despacho distribuido y la evidencia de ejecución.

La plataforma será el punto de entrada. Las personas no recibirán credenciales SSH de las VMs. Una futura terminal web abrirá únicamente el entorno autorizado del módulo.

El destino será una combinación explícita de VM, entorno Podman y repositorio/módulo. Un archivo que define el entorno no contiene necesariamente el código: hay que registrar y proteger también su almacenamiento. El usuario del módulo no podrá modificar la configuración que determina sus propios límites de acceso.

## Arquitectura propuesta

Navegador → API autenticada → autorización → cola de trabajos → trabajador del orquestador → ejecutor restringido en VM → entorno del módulo → Pi y pi-harness.

La API administra identidades, asignaciones y trabajos. El trabajador adapta las solicitudes a los scripts existentes. El ejecutor remoto acepta exclusivamente destinos y operaciones registrados; no ofrece un intérprete de comandos arbitrarios al navegador.

Se propone inicialmente Vue 3 para la interfaz, un servicio Node.js con TypeScript para la API y PostgreSQL para usuarios, permisos, trabajos y auditoría. La cola inicial puede residir en PostgreSQL, con reserva transaccional de trabajos. Son decisiones propuestas, no dependencias ya instaladas. La coordinación de Pi continúa en shell; no se introduce Python en el nuevo servicio.

El SQLite del Memory Gateway continúa independiente. No reutilizar sus identidades de servicio como cuentas humanas.

## Modelo de acceso

Entidades mínimas:

- Usuario: identidad, estado activo y rol.
- VM: conexión administrada, estado y ámbito administrativo.
- Entorno: VM, identidad de ejecución, definición Podman y almacenamiento autorizado.
- Repositorio/módulo: entorno, rol de agente, origen Git y memoria correspondiente.
- Asignación: usuario, destino y acciones permitidas.
- Trabajo: solicitante, destinos autorizados, política, estado y ejecuciones.
- Evento de auditoría: actor, acción, recurso, decisión y resultado.

Roles iniciales: administrador y operador. El administrador solo administra el ámbito que tenga concedido; las asignaciones explícitas determinan los destinos del operador. Acceder a una VM no concede acceso a todos sus entornos.

Separar las acciones de consultar, ejecutar cambios, publicar en Git, abrir terminal y administrar asignaciones. Denegar lo no concedido. Los identificadores o rutas enviados por el navegador no constituyen una autorización.

Si existe un único destino permitido se preselecciona; si hay varios, el usuario puede elegir. El análisis automático puede repartir una solicitud únicamente entre destinos autorizados. Una ambigüedad debe pedir precisión, nunca elegir arbitrariamente otro módulo.

## Fase 0. Asegurar la base existente

1. Preparar un entorno de pruebas con Node 24 y jq; registrar los resultados reales de las suites.
2. Corregir el analista LLM para resolver por perfil y repositorio, validar la respuesta y rechazar destinos desconocidos. Conservar restricciones generales de la solicitud.
3. Sustituir el candado de comprobación y touch por adquisición atómica. Añadir coordinación por repositorio entre solicitudes distintas.
4. Crear un checkout o worktree limpio por ejecución desde una referencia base explícita. Rechazar errores de preparación y no incorporar cambios ajenos.
5. Distinguir publicación de rama, PR creado y enlace para crear PR. Propagar los fallos como estados reales.
6. Limitar el piloto a backend y frontend; documentar QA y seguridad como pendientes hasta completar políticas y pruebas.

Archivos principales: tools/orquestacion/analizar_con_llm.py, tools/orquestacion/analizar_requisitos.sh, tools/despacho/validar_y_despachar.sh y tools/despacho/despachar_vm.sh.

Criterio de salida: dos repositorios en una misma VM se enrutan correctamente; dos solicitudes no mezclan cambios ni duplican una misma ejecución.

## Fase 1. Validar el aislamiento en una VM de prueba

1. Registrar un entorno Podman por módulo, con cuenta de servicio sin privilegios y almacenamiento separado por ámbito de confianza.
2. Probar Pi y pi-harness dentro del entorno. El harness actual utiliza Bubblewrap en Linux; comprobar su compatibilidad dentro de Podman antes de elegir la configuración definitiva.
3. No resolver incompatibilidades activando contenedores privilegiados o deshabilitando silenciosamente el aislamiento. Si hace falta otro backend del harness, diseñarlo y probarlo explícitamente.
4. Mantener las definiciones de contenedores bajo control administrativo. No montar el socket de Podman, las credenciales administrativas ni repositorios vecinos en el entorno del agente.
5. Implementar un ejecutor remoto con operaciones limitadas, destinos registrados y verificación de identidad y autorización del trabajo. Restringir la conexión técnica del orquestador a ese ejecutor.
6. Verificar la identidad SSH del servidor mediante claves conocidas. Separar las credenciales de publicación Git de la ejecución del agente.

Criterio de salida: una ejecución autorizada modifica su copia de trabajo; intentos de acceder a otro módulo, al host o al control de contenedores son rechazados. El aislamiento no se considera demostrado solo porque el proceso corre en un contenedor.

## Fase 2. Identidad, asignaciones y API

1. Implementar inicio y cierre de sesión mediante un proveedor de identidad estándar, y vincular su identidad estable al usuario local.
2. Crear el modelo de datos, migraciones y administración de asignaciones. No implementar recuperación de contraseñas ni criptografía propia en el MVP.
3. Aplicar autorización en el servidor a cada operación, incluyendo lectura de trabajos, logs y descargas.
4. Registrar la versión de permisos utilizada y comprobar su vigencia antes de despachar. Al revocar acceso, cancelar trabajos pendientes y cerrar terminales; definir cancelación controlada para ejecuciones activas y bloquear nuevas publicaciones.
5. Proteger sesiones, limitar solicitudes y evitar que credenciales aparezcan en el cliente o en los logs.

Criterio de salida: un operador no puede consultar ni ejecutar sobre destinos ajenos cambiando parámetros de una petición.

## Fase 3. Integrar la cola con los scripts

1. Crear trabajos persistentes con estados: pendiente, autorizado, ejecutando, completado, fallido y cancelado; añadir resultado por destino.
2. Generar en el servidor un inventario limitado al usuario antes de llamar al recolector y al analista. No permitir que el cliente sustituya rutas de configuración mediante variables de entorno.
3. Extender el destino desde perfil/repositorio a perfil/entorno/repositorio. Mantener un registro administrativo único y generar la configuración técnica consumida por los scripts.
4. Pasar prompts como datos mediante argumentos estructurados o entrada estándar; nunca construir comandos ejecutables desde texto del usuario.
5. Incorporar solicitante, destino, permisos y ejecución a la evidencia, sin incluir secretos.
6. Añadir reserva de trabajos, latido, cancelación y recuperación tras desconexiones. Consultar el estado remoto antes de reintentar: un timeout no prueba que la ejecución no comenzó.
7. Conservar paralelismo entre destinos independientes; coordinar ejecuciones y publicaciones sobre un mismo repositorio.

Archivos principales: tools/orquestacion/orquestar.sh, tools/orquestacion/recolectar_contexto_memoria.sh y tools/despacho/*.sh.

Criterio de salida: una solicitud web completa el flujo y produce evidencia atribuible; un reinicio del trabajador no duplica su ejecución.

## Fase 4. Memoria y resultados con el mismo alcance de permisos

1. Filtrar tecnologías y memoria antes de enviarlas al analista. El inventario global actual no debe llegar a usuarios sin autorización.
2. Extender la autorización del Gateway cuando su alcance por core o tenant sea demasiado amplio para las asignaciones por módulo.
3. Distinguir contratos compartidos autorizados de código y memoria de negocio privados. Consultar un contrato de otro módulo no concede permiso para ejecutar cambios en él.
4. Usar identidades de servicio limitadas al ámbito necesario; impedir que el agente elija otro ámbito libremente.
5. Aplicar controles a reportes, logs, búsquedas y visualización de grafos. La interfaz actual del visor es administrativa y no debe exponerse directamente como visor de operadores.

Criterio de salida: ni la búsqueda ni los reportes revelan información privada de destinos no asignados.

## Fase 5. Interfaz del MVP

- Acceso y sesión.
- Administración de usuarios, VMs, entornos y asignaciones.
- Lista de destinos permitidos y formulario de solicitud.
- Seguimiento de trabajos y resultados por módulo.
- Evidencia y publicación Git con estados explícitos.

La interfaz oculta operaciones no permitidas, pero la API vuelve a comprobarlas. No expone certificados, claves SSH ni controles administrativos de Podman.

Criterio de salida: un administrador asigna un módulo a un operador; el operador inicia sesión, envía una tarea y consulta exclusivamente sus resultados autorizados.

## Fase 6. Terminal web restringida

Implementarla después del MVP de prompts. Abrir una sesión temporal dentro del entorno autorizado, con autenticación, expiración y comprobación de permisos. No proporcionar shell general del host ni facultad de cambiar montajes o contenedores.

La terminal debe tener permiso independiente y coordinación con las tareas del agente para evitar escrituras simultáneas. Registrar apertura, cierre y destino; definir expresamente la retención antes de grabar contenidos de terminal que puedan contener secretos.

Criterio de salida: la terminal solo accede al módulo autorizado, se cierra al revocar permisos y no obtiene capacidades adicionales respecto a las concedidas.

## Piloto y orden de entrega

Primer corte: fase 0 y prueba de aislamiento de fase 1. Es la primera implementación que conviene realizar, antes de construir toda la interfaz.

Segundo corte: una VM de laboratorio con dos módulos separados, un administrador y dos operadores con asignaciones distintas. Integrar fases 2 a 5 con una solicitud de solo lectura y después un cambio controlado. Probar publicación únicamente en repositorios de prueba.

Tercer corte: ampliar a varias VMs y operadores; después incorporar la terminal de fase 6.

Pruebas obligatorias del piloto: acceso cruzado denegado, LLM que propone destino ajeno rechazado, revocación, lectura sin escritura, aislamiento de memoria, concurrencia, caída del trabajador y fallo de publicación.

Activar la plataforma solo para destinos migrados y validados. El flujo CLI anterior puede mantenerse como herramienta administrativa restringida; no debe convertirse en una vía alternativa para operadores. Ante un fallo del aislamiento, detener los despachos de ese destino, sin volver automáticamente a ejecución directa sobre el host.

## Documentación y decisiones pendientes

Actualizar README y AGENTS.md con el flujo real, dependencias, instalación, permisos y límites del piloto. Mantener un registro de pruebas verificables en lugar de una afirmación genérica de que todas pasan.

Antes de desplegar: elegir proveedor de identidad, confirmar capacidad y sistema operativo de la VM de prueba, definir la ubicación de los repositorios dentro del entorno y confirmar el stack propuesto para la plataforma. Estas decisiones no impiden iniciar la corrección del enrutamiento y los candados.

Referencia técnica de contenedores: https://docs.podman.io/en/stable/markdown/podman.1.html
