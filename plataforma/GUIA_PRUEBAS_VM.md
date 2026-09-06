# Preparar VMs y probar la plataforma multiusuario

Esta guía continúa el [README principal](../README.md). Los comandos de diagnóstico y pruebas existentes son ejecutables; los apartados marcados como pendientes requieren completar la implementación antes de habilitar tareas. No hay todavía un provisionador automático de extremo a extremo para esta arquitectura.

## 1. Resolver el acceso a la VM de laboratorio

VM comunicada por el usuario: `192.168.1.119`, acceso inicial por consola como `root`. La conexión TCP/SSH funciona y el equipo ofrece su llave ED25519, pero el servidor la rechaza. No se ha podido inspeccionar ni configurar la VM por SSH. Cambiar la contraseña no resolvió el acceso; la causa exacta sigue sin confirmar.

En la **consola de la VM**, como root:

```bash
cat /etc/os-release
ls -ld /root /root/.ssh /root/.ssh/authorized_keys
ssh-keygen -lf /root/.ssh/authorized_keys
/usr/sbin/sshd -T | grep -E '^(permitrootlogin|pubkeyauthentication|authorizedkeysfile|authenticationmethods) '
journalctl -u ssh -n 50 --no-pager
```

En el **equipo que ejecutará SSH**:

```bash
ssh-keygen -lf ~/.ssh/id_ed25519.pub
ssh -v -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 root@192.168.1.119
```

Comprobar que ambas huellas coincidan, que la llave pública esté completa en una sola línea y que el archivo y sus directorios pertenezcan al usuario correcto. Para root, `.ssh` debe tener modo 700 y `authorized_keys` modo 600. Revisar también reglas `Match`, `AllowUsers` o `DenyUsers` si los registros lo requieren; la configuración efectiva puede depender del usuario y la dirección de origen. No cambiar reglas de autenticación a ciegas ni compartir contraseñas o llaves privadas.

El acceso root es únicamente para preparación administrativa. El trabajador usará después una identidad de servicio restringida. Si la VM prohíbe root por SSH, preparar esa cuenta desde su consola y continuar mediante ella.

## 2. Preparar cada VM

Registrar su distribución/versión, dirección, usuario de servicio y capacidad disponible. Instalar Podman y sus dependencias rootless según el sistema; el host remoto también necesita Bash, Git, jq, OpenSSH y util-linux (`flock`). Bubblewrap y Pi están incluidos en la imagen del módulo.

Crear una cuenta de servicio, por ejemplo `orquestador`, con directorio propio y rangos de UID/GID subordinados sin solapamientos. Ejecutar Podman como esa cuenta, sin sudo. Verificar desde su sesión:

```bash
id
podman version
podman info --format '{{.Host.Security.Rootless}}'
cat /etc/subuid
cat /etc/subgid
```

El valor rootless debe ser `true`. Las personas que usan la web no reciben esta cuenta ni acceso a su socket. Para un servicio permanente falta configurar y probar el arranque tras reiniciar la VM.

Copiar una versión revisada del código fuente a un directorio de laboratorio de la VM. No copiar `.private`, credenciales centrales, logs ni repositorios ajenos. La imagen se construye desde la raíz de esa copia del repositorio.

## 3. Probar primero el aislamiento

Desde la raíz del código en la VM, como usuario de servicio:

```bash
bash plataforma/bin/probar_aislamiento_podman.sh
```

El script construye `Containerfile.modulo`, crea recursos temporales, comprueba el volumen propio, raíz de solo lectura, ausencia de sockets y una ejecución real de Bubblewrap. Limpia el contenedor y volumen temporales; conserva la imagen construida. No necesita credenciales de modelos ni ejecuta una tarea Pi.

En el equipo local se obtuvo:

```text
bwrap: Can't mount proc on /newroot/proc: Operation not permitted
```

Si ocurre en la VM, detener la habilitación y diagnosticar namespaces/políticas del host. No usar `--privileged` ni retirar protecciones como solución. Un `doctor` satisfactorio no basta: hay que ejecutar la prueba real. Superarla tampoco sustituye las pruebas completas siguientes.

## 4. Preparar dos módulos separados — instalación pendiente

Para demostrar aislamiento, usar dos repositorios desechables, por ejemplo `comentarios-prueba` y `pagos-prueba`, con un archivo distintivo en cada uno. No usar código productivo en el primer ensayo.

Por cada módulo:

1. Construir su imagen con Pi, pi-harness, agente y script fijo. `Containerfile.modulo` contiene la base frontend; backend necesita una variante con PHP/Composer y dependencias del proyecto.
2. Crear un volumen exclusivo y montar solo ese volumen en `/workspace`. Preparar su propiedad para el usuario interno `1000:1000`.
3. Colocar el repositorio en `/workspace/repositorio`. Debe resolver `origin/main`, o una referencia administrativa definida mediante `REPOSITORY_BASE_REF`. El ejecutor clona el commit en una copia por trabajo; no hace pull del repositorio base automáticamente.
4. Crear el contenedor con raíz de solo lectura, usuario `1000:1000`, todas las capacidades retiradas, `no-new-privileges`, límites de recursos y sin namespaces de host. No montar sockets del motor, llaves administrativas ni volúmenes de otros módulos.
5. Contrastar `podman inspect` con las comprobaciones reales de `remoto/ejecutor_podman.sh`, especialmente capacidades y montajes. La compatibilidad exacta aún está pendiente de prueba.
6. Completar la instalación de credenciales limitadas del proveedor de Pi y su salida de red necesaria. La prueba de aislamiento usa `--network none`; ese contenedor temporal no sirve tal cual para llamar a un proveedor externo. No exponer credenciales mediante el prompt ni ampliar montajes sin revisar el aislamiento.

Estos pasos todavía no tienen un instalador automatizado ni una receta final validada. No declarar el destino preparado solo por haber construido la imagen.

## 5. Conectar los registros con la plataforma — pendiente de piloto

En la web, registrar la VM, crear sus módulos y asignar permisos al usuario de prueba. Obtener el UUID real de cada destino en la respuesta de la API administrativa; los UUID de los ejemplos son ficticios.

| Ubicación | Configuración requerida |
|---|---|
| PostgreSQL / plataforma | Destino con VM, repositorio, contenedor y stack; asignaciones por usuario |
| Servidor central | Copia privada de `config/worker.example.json`, indexada por UUID del destino, con host, usuario de servicio, puerto, llave, known_hosts y metadatos coincidentes |
| VM | Registro basado en `config/remoto.example.json`, con el mismo UUID, contenedor, repositorio, rol y volumen |
| SSH de servicio | Llave exclusiva del trabajador, host conocido y comando forzado que invoque el ejecutor remoto |

Instalar `remoto/ejecutor_podman.sh` y el registro bajo control administrativo, fuera de los volúmenes editables por los agentes. La llave de servicio debe restringir el acceso al comando forzado, sin terminal ni reenvíos. El adaptador solicita exactamente `orquestador-v1`; no necesita una consola de propósito general. Mantener una vía administrativa separada para mantenimiento.

Mantener `isolationVerified: false`, `enabled: false` y `execution_ready=false` hasta completar el piloto. **Falta implementar el procedimiento de aprobación auditada de preparación**; no existe todavía un botón o CLI que haga estas verificaciones y active todo de forma segura.

## 6. Preparar el trabajador central — despliegue pendiente

`bin/iniciar_podman.sh` levanta API/web y PostgreSQL, pero no el trabajador. Este tiene entrada compilada `node dist/worker-main.js` en la imagen del servidor y requiere:

- `DATABASE_URL`: acceso de aplicación a PostgreSQL mediante configuración privada.
- `WORKER_REGISTRY`: ruta interna al registro administrativo.
- `WORKER_RUNS`: directorio privado y persistente de ejecuciones, escribible por el trabajador.
- Llave SSH y `known_hosts` disponibles en las rutas internas declaradas en el registro, con permisos apropiados.
- Acceso de red a PostgreSQL y a las VMs autorizadas.

Falta incorporar y probar ese servicio Podman con sus montajes, reinicios y apagado. No montar el socket de Podman del servidor: el despacho remoto usa SSH. No basta con iniciar el proceso: primero hay que validar los módulos y cerrar el procedimiento de preparación.

## 7. Pruebas de aceptación

Ejecutar en orden, guardar UUID de trabajo/destino, resultado esperado, resultado observado y evidencia. No incluir secretos.

| Prueba | Resultado esperado |
|---|---|
| Usuario sin sesión | API protegida rechaza el acceso |
| Usuario A asignado solo a comentarios | Solo puede seleccionar comentarios |
| Solicitud directa a pagos manipulando el UUID | La API rechaza; no se ejecuta nada remoto |
| Administrador delegado de una VM | No puede administrar destinos de otra VM |
| Destino sin preparar | No admite trabajos |
| Prompt de lectura | Pi analiza su módulo sin modificar los archivos del repositorio; puede generarse evidencia administrativa |
| Prompt de escritura permitido | Cambio en la copia Git de esa tarea, sin alterar el repositorio base ni el otro módulo |
| Intento de leer otro módulo/host/socket | Denegado; no hay contenido ajeno en resultado ni logs del usuario |
| Solicitud repetida con la misma idempotencia | Un único trabajo |
| Dos trabajos sobre el mismo destino | No ejecutan simultáneamente |
| Revocación antes del despacho | El trabajo no se ejecuta |
| Revocación durante ejecución / corte SSH | No se declara detención remota sin evidencia; incertidumbre requiere conciliación |
| Cierre de sesión / cuenta desactivada | La sesión deja de servir |

La lectura/escritura, aislamiento cruzado y resultado de Pi deben comprobarse realmente en la VM. La prueba exitosa debe recorrer **web → API → cola → orquestador → SSH → Podman → Pi → resultado web**. Faltan consulta/cancelación remota confirmadas y operación de conciliación; no vaciar ni reencolar trabajos inciertos como atajo.

## 8. Pruebas automatizadas y continuidad

En el servidor de desarrollo, con Node 24+, jq y Podman:

```bash
npm ci --prefix plataforma --ignore-scripts
npm run build --prefix plataforma
bash plataforma/bin/probar_podman.sh
python3 tests/probar_analista_llm.py
bash tests/probar_candado_despacho.sh
bash tests/probar_automatizacion.sh
```

Estas pruebas no configuran una VM real. Último resultado: 19 pruebas de plataforma aprobadas; suite antigua detenida en la visualización de grafos del Memory Gateway. Consultar [el estado detallado](README.md#3-qué-se-verificó-realmente).

Antes de pasar a uso real: resolver pendientes del ejecutor/trabajador, revisar credenciales y memoria por módulo, ensayar respaldos/restauración, HTTPS y reinicios. Actualizar el registro de continuidad con evidencia de cada VM y módulo verificado; no marcar completado el flujo basándose solo en pruebas de API.
