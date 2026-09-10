# Orquestador distribuido de agentes con Pi y memoria compartida

Orquestación local por SSH, ejecución con Pi en VMs y memoria central mediante Gateway, SQLite/OpenAPI y Cognee.

Esta infraestructura requiere **una VM para el orquestador** y **una o más VMs de ejecución** para los agentes backend/frontend.

## Flujo completo

```mermaid
flowchart TD
    subgraph ORQ["VM o equipo donde está instalado el orquestador"]
        direction TD
        U["Prompt general"] --> C["Recolector de contexto"]
        U --> D["División inicial en<br/>requisitos pequeños"]

        INV["Inventario de módulos y VMs"] --> C
        TEC["Tecnología privada de la empresa"] --> C
        C -- "Busca memoria de la empresa<br/>y contratos compartidos" --> GW

        subgraph MEM["Memoria central"]
            GW["Memory Gateway<br/>mTLS + permisos"]
            GW --> COG["Cognee<br/>búsqueda semántica"]
            GW --> SQL["SQLite + OpenAPI<br/>fuente autoritativa"]
            SQL -- "indexa" --> COG
            COG -. "respaldo" .-> SQL
        end

        GW -- "Memoria relevante" --> CTX["Contexto completo"]
        C -- "Prompt + inventario<br/>+ tecnología" --> CTX
        CTX --> A["Analista central"]
        D --> A
        A --> RQ["Asigna los requisitos<br/>a los módulos correctos"]
        RQ --> P["Despacho paralelo<br/>a las VMs seleccionadas"]
        P -- "Después de recibir los resultados<br/>de todas las VMs" --> R["Consolida el reporte<br/>y la evidencia final"]
    end

    subgraph VMS["Cada VM"]
        H["Pi + agente especializado"]
        H --> W["Trabaja únicamente en<br/>su repositorio autorizado"]
        H -- "Lee" --> BM["Memoria de negocio<br/>local del módulo"]
    end

    P --> H
    H -- "Consulta o publica contratos" --> MEM
```

El contenedor principal del diagrama representa el proceso que ocurre en la VM o equipo del orquestador. El bloque **Cada VM** representa las máquinas de ejecución externas a las que el orquestador envía el trabajo. El orquestador espera los resultados de todas las VMs y después consolida el reporte y la evidencia final.

## Guía de instalación de memoria en la VM del orquestador

Ejecutar desde la raíz del repositorio en la VM del orquestador. Mantener abiertas las terminales de los servicios.

### 1. Comprobar requisitos

Requisitos: Node.js 24+, Python 3.10+ (con el módulo `venv`), Git, SSH, jq y Ollama. Modelo: `hermes3:latest`.

**a) Paquetes del sistema (jq y Python venv)**

macOS (Homebrew):

**Dónde se ejecuta:** en la VM del orquestador, o en el equipo donde se esté instalando el orquestador.

```bash
brew install jq
```

Linux (Debian/Ubuntu):

**Dónde se ejecuta:** en la VM del orquestador, o en el equipo donde se esté instalando el orquestador.

```bash
sudo apt-get update && sudo apt-get install -y jq python3-venv "python3.$(python3 -c 'import sys; print(sys.version_info[1])')-venv"
```

**b) Instalar Ollama**

macOS (Homebrew):

**Dónde se ejecuta:** en la VM del orquestador, o en el equipo donde se esté instalando el orquestador.

```bash
brew install ollama
```

Linux:

**Dónde se ejecuta:** en la VM del orquestador, o en el equipo donde se esté instalando el orquestador.

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

**c) Descargar y verificar el modelo**

**Dónde se ejecuta:** en la VM del orquestador, o en el equipo donde se esté instalando el orquestador.

```bash
ollama pull hermes3:latest
ollama list | grep hermes3
```

**d) Descargar el repositorio**

**Dónde se ejecuta:** en la VM del orquestador, o en el equipo donde se esté instalando el orquestador.

```bash
git clone git@github.com:CarlosPull/prueba_agentes.git
cd prueba_agentes
```

**e) Cambiar a la rama de trabajo del repositorio**

**Dónde se ejecuta:** en la VM o equipo donde se esté instalando el orquestador, dentro del repositorio recién descargado.

```bash
git checkout dev
```

Requisitos de hardware para `hermes3:latest` (8B):

| Recurso | Mínimo | Recomendado |
| --- | --- | --- |
| GPU | 6 GB VRAM (o CPU sin GPU) | 8 GB+ VRAM (NVIDIA/Apple Silicon) |
| RAM | 6 GB | 16 GB |

> Es posible utilizar el equipo local sin GPU dedicada siempre y cuando cuente con al menos 16 GB de RAM; la inferencia se ejecutará sobre CPU y será más lenta.

### 2. Preparar el entorno y los certificados — una sola vez

No sobrescribir configuraciones privadas existentes. Para acceso desde VMs, configurar dirección accesible y certificados mediante las herramientas del Gateway.

**a) Crear el directorio privado y el entorno virtual de Python**

Aísla las dependencias de Cognee (`uvicorn`, `fastembed`, etc.) del resto del sistema.

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador, desde la raíz del repositorio.

```bash
mkdir -p .private
python3 -m venv .private/cognee-venv
.private/cognee-venv/bin/pip install --upgrade pip
.private/cognee-venv/bin/pip install cognee uvicorn fastembed
```

**b) Generar los certificados PKI del Memory Gateway**

Crea la autoridad certificadora y los certificados mTLS que usarán el Gateway y sus clientes (backend, frontend, analista, admin).

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador, desde la raíz del repositorio.

```bash
./memory-gateway/bin/generar_pki.sh .private/memory-gateway-pki 127.0.0.1 backend frontend orchestrator-analyst memory-admin
cp .private/memory-gateway-pki/server.key .private/memory-gateway-pki/server-local.key
cp .private/memory-gateway-pki/server.crt .private/memory-gateway-pki/server-local.crt
```

**c) Preparar la configuración local del Gateway**

Copia las plantillas de ejemplo a `.private/` (fuera de Git) para personalizarlas sin afectar el repositorio.

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador, desde la raíz del repositorio.

```bash
mkdir -p .private/memory-gateway-data/openapi
cp memory-gateway/config/clients.example.json .private/memory-gateway-clients.json
cp memoria/tecnologias.example.json .private/tecnologias.json
```

### 3. Iniciar Cognee — terminal 1

Ollama debe estar activo. Conservar las rutas de datos; las variables de Ladybug del ejemplo corresponden a una biblioteca `.dylib`: omitirlas en Linux o si la biblioteca no está instalada.

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador, en una terminal que debe permanecer abierta mientras Cognee esté en uso.

```bash
cd <ruta_del_repositorio>
PROJECT_ROOT="$PWD"

env \
  SYSTEM_ROOT_DIRECTORY="$PROJECT_ROOT/.private/cognee-system" \
  DATA_ROOT_DIRECTORY="$PROJECT_ROOT/.private/cognee-data" \
  COGNEE_LOGS_DIR="$PROJECT_ROOT/.private/cognee-logs" \
  LBUG_C_API_LIB_PATH="$PROJECT_ROOT/.private/ladybug-v0.19.0/liblbug.dylib" \
  DYLD_LIBRARY_PATH="$PROJECT_ROOT/.private/ladybug-v0.19.0" \
  REQUIRE_AUTHENTICATION=false \
  ENABLE_BACKEND_ACCESS_CONTROL=false \
  VECTOR_DB_PROVIDER=lancedb \
  LLM_PROVIDER=ollama \
  LLM_MODEL=hermes3:latest \
  LLM_ENDPOINT=http://127.0.0.1:11434 \
  LLM_API_KEY=ollama \
  EMBEDDING_PROVIDER=fastembed \
  EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2 \
  EMBEDDING_DIMENSIONS=384 \
  "$PROJECT_ROOT/.private/cognee-venv/bin/uvicorn" \
  cognee.api.client:app --host 127.0.0.1 --port 8000
```

### 4. Iniciar Memory Gateway — terminal 2

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador, en una segunda terminal que debe permanecer abierta mientras el Gateway esté en uso.

```bash
cd <ruta_del_repositorio>
PROJECT_ROOT="$PWD"

env \
  MEMORY_GATEWAY_HOST=127.0.0.1 \
  MEMORY_GATEWAY_PORT=9443 \
  MEMORY_GATEWAY_DB="$PROJECT_ROOT/.private/memory-gateway-data/gateway.sqlite" \
  MEMORY_GATEWAY_CLIENTS="$PROJECT_ROOT/.private/memory-gateway-clients.json" \
  MEMORY_GATEWAY_OPENAPI_DIR="$PROJECT_ROOT/.private/memory-gateway-data/openapi" \
  MEMORY_GATEWAY_TLS_KEY="$PROJECT_ROOT/.private/memory-gateway-pki/server-local.key" \
  MEMORY_GATEWAY_TLS_CERT="$PROJECT_ROOT/.private/memory-gateway-pki/server-local.crt" \
  MEMORY_GATEWAY_TLS_CA="$PROJECT_ROOT/.private/memory-gateway-pki/ca.crt" \
  COGNEE_BASE_URL=http://127.0.0.1:8000 \
  node memory-gateway/bin/memory-gateway.mjs
```

## Provisionamiento de una VM Pi

### 1. Preparar el acceso SSH

Habilitar SSH en la VM y disponer de acceso al repositorio Git. Desde la VM del orquestador:

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador, desde la raíz del repositorio.

```bash
./tools/vms/configurar_ssh_vm.sh <usuario>@<ip>
```

Este comando configura únicamente la conexión desde el orquestador hacia la VM. La autenticación de la VM contra GitHub se configura después dentro del provisionador, mediante URL con token o una clave SSH dedicada.

### 2. Ejecutar el provisionador desde la VM del orquestador

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador, desde la raíz del repositorio. El script se conecta a la VM de destino y realiza allí la instalación necesaria.

Un **perfil es el identificador único que el orquestador utiliza para reconocer una configuración de trabajo**. Dicho de forma sencilla: es el nombre con el que se registra una VM junto con el proyecto y el agente que trabajarán en ella. El perfil reúne la dirección y el usuario de la VM, el proyecto, módulo, stack, agente, workspace, versiones y opciones de memoria. Se guarda como una entrada independiente en `config/vms.json`, por lo que pueden existir varios perfiles del mismo stack; por ejemplo, `backend`, `backend-prueba` y `frontend-ventas`.

En el comando siguiente, `<perfil>` se reemplaza por ese nombre. Si el perfil todavía no existe, el provisionador abre el asistente para crearlo. Si ya existe, reutiliza su configuración guardada para provisionar o actualizar el mismo destino.

```bash
./tools/vms/provisionar_vm_pi.sh <perfil> --con-sudo-interactivo
```

Instala automáticamente NVM, Node.js, Pi, el harness y los paquetes del sistema; configura el perfil, proyecto, agente y memoria. No instalar Node ni Pi manualmente.

El nombre del perfil se escribe en el comando antes de iniciar el asistente. Después, al crear un perfil nuevo, el asistente solicita los demás datos en este orden. En esta guía, **VM** significa máquina virtual: el equipo remoto donde se instalará el proyecto y trabajará el agente. Pulsar **Enter** acepta el valor predeterminado que aparece entre paréntesis.

| Dato solicitado | Para qué sirve | Qué debe indicar el usuario |
| --- | --- | --- |
| Identificador del perfil (`<perfil>`) | Es el identificador único que permite al orquestador saber qué VM, proyecto, módulo y agente debe utilizar. No es lo mismo que el stack: un perfil puede llamarse `backend-prueba`, mientras que su stack sigue siendo `backend`. | Escribir un nombre corto, descriptivo y sin espacios; por ejemplo, `backend`, `backend-prueba` o `frontend-ventas`. Este mismo nombre debe usarse cada vez que otro comando solicite `<perfil>`. Se escribe como argumento del comando, no dentro del asistente. |
| IP de la VM | Permite que el orquestador encuentre por red la máquina que preparará y utilizará para ejecutar las tareas. | La dirección IP o el nombre de red de la VM; por ejemplo, `192.168.50.62`. |
| Usuario de Ubuntu | Indica con qué cuenta se abrirá la conexión remota segura (SSH) y en qué carpeta personal se instalarán las herramientas. | Un usuario que exista en la VM, tenga acceso por SSH y pueda usar `sudo` cuando la instalación lo requiera; por ejemplo, `serveradmin`. |
| Origen del proyecto | Define desde dónde se obtendrá el código que se copiará o clonará en la VM. Esta elección afecta al proyecto, no al agente. | `local` si el repositorio ya está en la VM del orquestador; `git` si debe descargarse desde un repositorio Git remoto. |
| Repositorio local | Permite elegir exactamente qué proyecto local se enviará a la VM. Solo se solicita cuando el origen es `local`. | Seleccionar un repositorio de la lista o escribir su ruta completa si no aparece. |
| URL y rama del proyecto | Identifican el repositorio remoto y la versión del código que se instalará. Solo se solicitan cuando el origen es `git`. | La URL HTTPS del repositorio y la rama deseada, normalmente `main`. Para un repositorio privado se puede usar temporalmente `https://usuario:TOKEN@github.com/owner/repo.git`; el token no se guarda en la configuración. |
| Autenticación de GitHub | Autoriza la descarga cuando el repositorio es privado. El asistente ofrece dos métodos. | Elegir `1` para una URL HTTPS con usuario y token, o `2` para generar una clave SSH dedicada dentro de la VM. |
| Stack | Señala qué parte de una aplicación atenderá esta VM y permite asignarle las reglas de trabajo correspondientes. | `backend` para servicios, API, base de datos o lógica del servidor; `frontend` para interfaz visual y código que utiliza el navegador. |
| ID del repositorio | Da al proyecto un identificador estable dentro del orquestador para relacionar tareas, tecnología y memoria. | Un nombre corto y único, sin espacios; normalmente se acepta el nombre propuesto del repositorio. Ejemplo: `sistema-ventas`. |
| Nombre del módulo | Identifica la parte funcional concreta que contiene el repositorio cuando un sistema está dividido en varios componentes. | El nombre del componente, sin espacios; por ejemplo, `facturacion`. Si el repositorio es un único componente, se puede aceptar el valor propuesto. |
| Tipo de repositorio backend | Permite distinguir el núcleo compartido del sistema de un módulo que depende de él. Solo se solicita para `backend`. | `core` si contiene contratos o funciones centrales compartidas; `module` si contiene una función específica del negocio. Ante la duda, usar `module`. |
| Alias de enrutamiento | Ayudan al orquestador a reconocer distintas formas en que una persona puede mencionar el módulo y enviarle la tarea correcta. | Nombres alternativos separados por comas; por ejemplo, `facturacion,facturas,cobros`. |
| Agente | Define las instrucciones y especialidad que Pi utilizará al trabajar en ese proyecto. | Elegir un agente de la lista. El valor habitual es `dev-back` para backend y `dev-front` para frontend. |
| Workspace remoto | Indica la carpeta de la VM donde quedará el código y desde dónde se ejecutarán las tareas. | Una ruta dentro de la carpeta personal del usuario de Ubuntu; por ejemplo, `/home/serveradmin/sistema-ventas`. Normalmente basta aceptar la propuesta. |
| Forma de actualizar el agente | Decide cómo recibirá la VM los cambios realizados en las instrucciones del agente. No cambia la forma en que se obtiene el proyecto. | `git` para descargar cambios de los agentes publicados en Git; `local` para recibir cambios desde la VM del orquestador. |
| Repositorio y rama del agente | Indican dónde están publicadas las instrucciones del agente que la VM debe mantener actualizadas. Solo se solicitan al elegir actualización por `git`. | La URL del repositorio de este orquestador y la rama donde se publican los agentes. Si los valores propuestos son correctos, pulsar **Enter**. |
| Intervalo de actualización del agente | Define cada cuántos segundos la VM comprobará si existen instrucciones nuevas del agente. Solo se solicita al elegir actualización por `git`. | Uno de estos valores: `10`, `15`, `20`, `30` o `60`. Un intervalo menor actualiza antes, pero realiza más consultas; `30` es el valor habitual. |
| Versión de Node.js | Instala la versión de Node.js que necesita Pi y evita diferencias entre VMs. | Una versión completa con tres números, como `24.19.0`. Normalmente se acepta la propuesta. |
| Versión de Pi | Determina qué versión del motor que ejecuta al agente se instalará. | `latest` para instalar la versión más reciente disponible, o una versión concreta si el proyecto exige fijarla. |
| Versión de PHP | Instala la familia de PHP con la que se ejecutará un proyecto backend. Solo se solicita para `backend`. | La versión principal y secundaria; por ejemplo, `8.4`. Debe ser compatible con el proyecto. |
| Versión mínima de PHP | Impide continuar si la VM no dispone de una versión suficientemente reciente para el proyecto. Solo se solicita para `backend`. | La versión mínima completa exigida; por ejemplo, `8.4.1`. |
| Habilitar Memory Gateway | Permite que el agente consulte contexto compartido, como contratos técnicos y memoria del negocio, mediante una conexión protegida con certificados mTLS. | `s` para habilitarlo o `N` para continuar sin memoria compartida. `N` es el valor predeterminado. |
| URL del Memory Gateway | Indica en qué servidor y puerto se encuentra el servicio de memoria compartida. Solo se solicita si se habilita Memory Gateway. | Una URL como `https://192.168.50.61:9443`, usando la IP o el nombre de red del equipo donde funciona el orquestador. No usar `127.0.0.1` desde otra VM. |
| Core ID | Selecciona el núcleo del sistema cuyos contratos y conocimientos compartidos podrá consultar este proyecto. Solo se solicita si se habilita Memory Gateway. | El identificador del core configurado y autorizado en el Gateway. Puede coincidir con el ID del repositorio si ese es realmente el core. |
| Tenant ID | Separa la memoria de una empresa u organización de la memoria perteneciente a otras. Solo se solicita si se habilita Memory Gateway. | El identificador de la empresa autorizado en el Gateway; por ejemplo, `empresa-prueba`. No usar el ejemplo si la instalación tiene otro tenant configurado. |

Con `--con-sudo-interactivo`, también se solicita la contraseña `sudo` de la VM cuando sea necesaria.

Para un repositorio privado, el token incluido en la URL debe pertenecer a una cuenta que ya tenga acceso y debe incluir permiso de lectura de contenido. Por ejemplo:

```text
https://usuario:TOKEN@github.com/owner/repo.git
```

El provisionador no usa esa URL literalmente como `origin`: separa la credencial y clona mediante un `GIT_ASKPASS` temporal para impedir que el token quede almacenado en Git. Como alternativa compatible con automatizaciones, se puede exportar temporalmente antes de ejecutar el provisionador:

```bash
export GITHUB_TOKEN='TOKEN_CON_ACCESO_AL_REPOSITORIO'
./tools/vms/provisionar_vm_pi.sh <perfil> --con-sudo-interactivo
```

Si se elige la opción SSH, el provisionador genera una clave ED25519 dedicada dentro de la VM, muestra únicamente su parte pública y se detiene. Hay que copiarla en `https://github.com/settings/ssh/new` desde una cuenta con acceso al repositorio, o agregarla como Deploy key de solo lectura. Al pulsar **Enter**, el provisionador verifica el repositorio y la rama antes de continuar. La clave privada nunca sale de la VM.


**Si la IP del Gateway es diferente o cambia:**

1. Indicar la URL correcta durante el asistente o modificar `memory.gateway_url` del perfil en `config/vms.json`; revisar también `memory.core_id` y `memory.tenant_id`.
2. En el servidor del Gateway, cambiar `MEMORY_GATEWAY_HOST=127.0.0.1` por la IP de su interfaz de red (o `0.0.0.0`) y permitir el puerto `9443` sólo desde los equipos autorizados. Mantener Cognee y el visor en localhost.
3. Usar un certificado de servidor cuyo SAN incluya la IP/DNS real, actualizar las rutas `MEMORY_GATEWAY_TLS_CERT` y `MEMORY_GATEWAY_TLS_KEY` si cambian y reiniciar el Gateway. Cambiar la URL no actualiza el certificado.
4. Verificar que la identidad cliente esté autorizada para el Core ID y Tenant ID en `.private/memory-gateway-clients.json`. Instalar o actualizar sus certificados en la VM de ejecución desde el orquestador:

   **Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador, desde la raíz del repositorio.

   ```bash
   ./tools/vms/sincronizar_mtls_vm.sh <perfil>
   ```

Conservar la CA existente; si se reemplaza, actualizar también la confianza de todos los clientes afectados.

### 3. Iniciar sesión en Pi dentro de la VM provisionada

Primero, abrir la conexión con la VM provisionada.

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador; también puede ejecutarse desde cualquier otro equipo que tenga acceso SSH a la VM provisionada.

```bash
ssh <usuario>@<ip>
```

Cuando la terminal ya muestre la sesión de la VM provisionada, iniciar Pi.

**Dónde se ejecuta:** dentro de la VM provisionada.

```bash
pi
```

Si no se reconoce `pi`, `node` o `npm`, cargar NVM en esa misma terminal de la VM y volver a abrir Pi:

**Dónde se ejecuta:** dentro de la VM provisionada.

```bash
source "$HOME/.nvm/nvm.sh"
pi
```

Iniciar sesión en Pi con la cuenta de Codex, sin `sudo`, antes de ejecutar tareas. Una vez dentro de Pi, seguir:

**Dónde se ejecuta:** dentro de Pi, abierto en la VM provisionada.

```text
/login
 → Sign in with an account
   OpenAI Codex unconfigured
   Device code login (headless)
```

### 4. Modificar el archivo de memoria de lógica de negocio

Editar el archivo de memoria de negocio del repositorio dentro de la VM provisionada, en `~/.local/share/prueba-agentes/business/<repositorio>.md`, y describir allí las reglas o lógica de negocio propias del módulo. El agente lee este archivo y lo tiene en cuenta durante el desarrollo, por lo que debe mantenerse actualizado con el conocimiento privado de ese repositorio.

Primero, conectarse a la VM provisionada si todavía no se tiene una sesión abierta.

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador; también puede ejecutarse desde cualquier otro equipo que tenga acceso SSH a la VM provisionada.

```bash
ssh <usuario>@<ip>
```

Después de entrar en la VM, abrir el archivo de memoria.

**Dónde se ejecuta:** dentro de la VM provisionada.

```bash
nano ~/.local/share/prueba-agentes/business/<repositorio>.md
```

### 5. Verificar la VM desde la VM del orquestador

Abrir otra terminal en la VM del orquestador, desde la raíz del repositorio:

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador, desde la raíz del repositorio.

```bash
./tools/vms/provisionar_vm_pi.sh <perfil> --solo-verificar
```

## Uso

Estos comandos se ejecutan **en la máquina orquestadora**, desde la raíz de este repositorio, no en las VMs de ejecución. Reemplazar los valores entre `<...>`.

### 1. Conectarse a la máquina orquestadora

Desde una terminal de tu equipo (omitir SSH si ya estás en el orquestador):

**Dónde se ejecuta:** en el equipo del usuario desde el que se accederá al orquestador.

```bash
ssh <usuario_orquestador>@<ip_orquestador>
```

Dentro de la máquina orquestadora:

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador, después de iniciar la sesión SSH.

```bash
cd <ruta_del_repositorio>/prueba_agentes
./tools/vms/probar_vms.sh
```

Si falta configurar el acceso SSH a una VM de ejecución, ejecutar desde el orquestador y repetir la comprobación:

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador, desde la raíz del repositorio.

```bash
./tools/vms/configurar_ssh_vm.sh <usuario_vm>@<ip_vm>
./tools/vms/probar_vms.sh
```

### 2. Ejecutar una tarea desde el orquestador

**Dónde se ejecuta:** en la VM o equipo donde está instalado el orquestador, desde la raíz del repositorio.

```bash
./tools/orquestacion/orquestar.sh "objetivo"
```

- Incluir el módulo de destino en la solicitud.
- Usar `solo lectura` o `sin modificar` para impedir escrituras.
- Los destinos independientes se ejecutan en paralelo.

### Alternativa: lanzar una tarea desde un equipo remoto

Cada usuario puede enviar su prompt por SSH sin abrir una sesión interactiva. La ejecución sigue ocurriendo en la máquina orquestadora:

**Dónde se ejecuta:** en el equipo remoto del usuario. El comando se conecta al orquestador y ejecuta allí la tarea.

```bash
ssh <usuario_orquestador>@<ip_orquestador> "cd '<ruta_del_repositorio>/prueba_agentes' && ./tools/orquestacion/orquestar.sh 'Prompt de cada usuario'"
```

Reemplazar usuario, IP, ruta absoluta del repositorio en el orquestador y prompt. El usuario remoto debe tener acceso SSH y el entorno del orquestador configurado.
