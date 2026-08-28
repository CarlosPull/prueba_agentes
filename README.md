# Orquestador distribuido de agentes con Pi

Este repositorio clasifica una solicitud, la divide en requisitos por dominio y ejecuta cada grupo dentro de su VM mediante Pi y `pi-harness`.

## Flujo principal

```bash
./tools/orquestar.sh "Crea una API Laravel para perfiles y una pantalla Vue para editarlos"
```

El orquestador:

1. Descompone la solicitud en requisitos backend, frontend, QA, seguridad o generales.
2. Crea una carpeta única en `proyectos/` con la solicitud y clasificación.
3. Verifica que las VMs Pi habilitadas estén disponibles.
4. Sincroniza el agente de cada VM desde la rama Git configurada.
5. Ejecuta backend y frontend en paralelo cuando ambos aparecen en la solicitud.
6. Espera todas las ejecuciones y genera `REPORTE_PI.md` y `EVIDENCIA_AGENTES.md`.

Pi y `pi-harness` viven dentro de las VMs. La Mac conserva el orquestador y envía únicamente las subtareas por SSH. Las políticas en `pi-harness/policies/` restringen los archivos que cada rol puede leer o modificar.

## Configuración

`vms.json` admite varios perfiles. Para despacho debe existir exactamente uno por stack con:

```json
{
  "stack": "backend",
  "engine": "pi",
  "dispatch_enabled": true,
  "pi_harness": "/home/usuario/.local/bin/pi-harness",
  "pi_provider": "openai-codex",
  "pi_model": "gpt-5.4-mini"
}
```

La VM backend Pi de prueba está en el perfil `backend-pi-prueba`. La VM frontend debe provisionarse con Pi antes de ejecutar solicitudes full-stack.

## Provisionamiento

```bash
./tools/provisionar_vm_pi.sh <perfil-vm> --con-sudo-interactivo
./tools/provisionar_vm_pi.sh <perfil-vm> --solo-verificar
```

Consulta [PROVISIONAMIENTO_VM_PI.md](PROVISIONAMIENTO_VM_PI.md) para el procedimiento completo.

## Diagnóstico

```bash
./tools/orquestar.sh --clasificar "objetivo"
./tools/orquestar.sh --descomponer "objetivo"
./tools/probar_vms.sh
./tests/probar_automatizacion.sh
```
