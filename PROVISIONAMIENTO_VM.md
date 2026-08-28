# Provisionamiento de VMs

El runtime vigente es Pi. La guía completa está en [PROVISIONAMIENTO_VM_PI.md](PROVISIONAMIENTO_VM_PI.md).

Para crear o completar un perfil:

```bash
./tools/provisionar_vm_pi.sh <perfil-vm> --con-sudo-interactivo
```

Para auditarlo sin reinstalar:

```bash
./tools/provisionar_vm_pi.sh <perfil-vm> --solo-verificar
```

El provisionador registra `engine: "pi"`, `dispatch_enabled: true`, `pi_harness`, proveedor y modelo en `vms.json`. Debe quedar exactamente un perfil habilitado para cada stack que se desee despachar.
