# Prompt 3: agent-runner-vm-backend

- Proveedor: `codex`
- Sandbox: `ssh:serveradmin@192.168.50.193:backend`
- Directorio: `/home/serveradmin/laravel-dev`
- Estado: `aprobado-para-envio`

## Contenido exacto enviado por el orquestador

```text
<skill>
# Requisitos: implementa un modulo de registro de usuarios

Generado: 2026-08-25T18:37:31-04:00

## Supuestos

- El backend vive en `/home/serveradmin/laravel-dev` y expone una API REST para el frontend.
- El frontend vive en `/home/serveradmin/vue-dev` y consumirá la API por HTTP sin acoplarse a Laravel internals.
- La URL base de la API será definida de forma explícita antes de implementar, por ejemplo bajo `/api/v1`.
- El registro inicial será con email y contraseña; cualquier campo adicional deberá quedar definido en el contrato antes de implementarse.
- El sistema usará autenticación basada en tokens para la sesión del usuario registrado, si el proyecto ya la soporta; si no, se dejará el contrato listo para integrarla.
- Los errores de validación y de negocio deberán compartirse como formato JSON estable entre backend y frontend.
- CORS deberá permitir únicamente el origen del frontend en entorno de desarrollo y los orígenes autorizados en producción.

## Requisitos categorizados

### REQ-001 — Definir contrato del registro

- Categoría: `general`
- Fase: `1`
- Agente: `dev-back`

Analizar y formalizar el contrato funcional y técnico del flujo de registro de usuarios, incluyendo payloads, respuestas, códigos HTTP, URL base, autenticación esperada, CORS y formato común de errores.

Criterios de aceptación:

- [ ] Existe un contrato JSON o documento equivalente con la ruta exacta del endpoint de registro.
- [ ] El contrato define campos de entrada obligatorios y opcionales.
- [ ] El contrato define respuestas exitosas, errores de validación y errores de negocio con códigos HTTP.
- [ ] El contrato especifica el formato JSON de error compartido y la URL base de la API.
- [ ] El contrato deja claro qué parte corresponde al backend y qué parte corresponde al frontend.

### REQ-002 — Implementar endpoint de registro

- Categoría: `backend`
- Fase: `1`
- Agente: `dev-back`

Crear en backend el endpoint REST para registrar usuarios, validar datos, persistir el usuario y devolver una respuesta consistente con el contrato definido.

Criterios de aceptación:

- [ ] El backend expone el endpoint de registro en la ruta acordada.
- [ ] La solicitud inválida devuelve errores de validación en el formato JSON compartido.
- [ ] El usuario se persiste correctamente con los campos definidos en el contrato.
- [ ] La respuesta exitosa devuelve un JSON consistente con el contrato y el código HTTP esperado.
- [ ] El flujo no expone datos sensibles como contraseñas o hashes.

### REQ-003 — Configurar autenticación post-registro

- Categoría: `backend`
- Fase: `1`
- Agente: `dev-back`

Definir e implementar en backend el comportamiento de autenticación posterior al registro, dejando listo el contrato para que el frontend reciba el resultado esperado.

Criterios de aceptación:

- [ ] El contrato indica si el registro inicia sesión automáticamente o solo crea la cuenta.
- [ ] Si se emite token, la respuesta lo incluye según el contrato.
- [ ] Si no se emite token, la respuesta lo indica explícitamente y sin ambigüedad.
- [ ] El comportamiento está cubierto por pruebas del backend.
- [ ] No se rompe la compatibilidad con el formato de error compartido.

### REQ-004 — Configurar seguridad de origen

- Categoría: `backend`
- Fase: `1`
- Agente: `dev-back`

Ajustar en backend las reglas de CORS y política de acceso para permitir el consumo desde el frontend acordado sin abrir orígenes innecesarios.

Criterios de aceptación:

- [ ] El backend acepta solicitudes desde el origen del frontend definido para desarrollo.
- [ ] Los orígenes permitidos en producción quedan parametrizados o documentados.
- [ ] Las solicitudes preflight necesarias responden correctamente.
- [ ] No se habilita acceso amplio sin justificación explícita.
- [ ] La configuración queda alineada con el contrato HTTP definido.

### REQ-005 — Crear formulario de registro

- Categoría: `frontend`
- Fase: `1`
- Agente: `dev-front`

Implementar en frontend la pantalla o componente de registro con campos, validación visual, estados de carga y envío al endpoint definido.

Criterios de aceptación:

- [ ] Existe una vista o componente de registro accesible desde la interfaz acordada.
- [ ] El formulario incluye los campos definidos en el contrato.
- [ ] La interfaz muestra estado de carga mientras se envía la solicitud.
- [ ] Los errores de validación se muestran en los campos o en un bloque accesible.
- [ ] El formulario consume exactamente el endpoint y método definidos por el contrato.

### REQ-006 — Manejar respuestas y errores

- Categoría: `frontend`
- Fase: `1`
- Agente: `dev-front`

Implementar en frontend el procesamiento de respuestas exitosas, errores de validación y errores generales usando el formato JSON compartido.

Criterios de aceptación:

- [ ] Las respuestas exitosas se manejan según el contrato sin suposiciones adicionales.
- [ ] Los errores de validación se mapean al formulario de forma consistente.
- [ ] Los errores generales muestran un mensaje usable para el usuario final.
- [ ] No se muestran datos técnicos internos del backend al usuario.
- [ ] El manejo de errores funciona con el formato JSON compartido definido en el contrato.

### REQ-007 — Verificar flujo completo

- Categoría: `qa`
- Fase: `2`
- Agente: `qa`

Diseñar y ejecutar pruebas para validar el flujo completo de registro entre backend y frontend, incluyendo casos felices, validaciones y errores de integración.

Criterios de aceptación:

- [ ] Existen casos de prueba para registro exitoso, campos obligatorios faltantes y error de negocio.
- [ ] Se verifica que backend y frontend respetan el contrato acordado.
- [ ] Se validan códigos HTTP y estructura JSON de respuestas.
- [ ] Se incluyen al menos casos límite relevantes como email duplicado y contraseña inválida.
- [ ] Los resultados de prueba permiten detectar regresiones del flujo de registro.
</skill>

<task>
Actúa como el agente `dev-back`.
MISIÓN: Diseñar, implementar y mantener backends modulares con PHP y Laravel. Convertir requisitos en módulos de dominio claros, APIs seguras y cambios verificables, respetando las convenciones del proyecto.
SKILLS: PHP 8 moderno y Laravel., Arquitectura modular orientada a dominios y responsabilidades., Controllers delgados, Form Requests, Actions o Services y DTOs., Eloquent ORM, relaciones, factories, seeders y migraciones., APIs REST, API Resources y contratos JSON consistentes., Autenticación y autorización con Sanctum, Policies y Gates., Colas, eventos, listeners, jobs y manejo centralizado de errores., Pruebas unitarias y Feature Tests con PHPUnit o Pest., Composer, Artisan, Pint y análisis estático con Larastan/PHPStan.
MEMORIA:
# Memoria: dev-back

Esta memoria contiene hechos persistentes y decisiones confirmadas del agente. No guardar secretos, tokens ni datos personales.

## Hechos

- El stack backend definido es PHP con Laravel.
- El código debe organizarse modularmente por dominio o responsabilidad.

## Decisiones

<!-- El runtime añade nuevas entradas debajo de esta línea. -->

- Mantener controllers delgados y colocar la lógica de negocio en Actions o Services según las convenciones del proyecto.
- Usar PHPUnit o Pest para pruebas y herramientas Laravel disponibles para validación de calidad.

SUBAGENTES Y RESPONSABILIDADES:
- generador-codigo: Convertir una especificación aprobada en código PHP/Laravel modular, claro y mantenible.
- qa: Revisar el código generado, detectar defectos y comprobar que satisface el requisito sin regresiones evidentes.
- documentador: Documentar de forma breve y precisa el cambio realizado para que otra persona pueda usarlo y mantenerlo.

Implementa exclusivamente los requisitos backend asignados usando PHP 8 y Laravel, con arquitectura modular. Trabaja solo dentro del workspace permitido por Agent Runner. Inspecciona primero lo existente, evita sobrescribir trabajo ajeno y ejecuta las validaciones disponibles.

REQ-002 — Implementar endpoint de registro
Crear en backend el endpoint REST para registrar usuarios, validar datos, persistir el usuario y devolver una respuesta consistente con el contrato definido.
Criterios de aceptación:
  - El backend expone el endpoint de registro en la ruta acordada.
  - La solicitud inválida devuelve errores de validación en el formato JSON compartido.
  - El usuario se persiste correctamente con los campos definidos en el contrato.
  - La respuesta exitosa devuelve un JSON consistente con el contrato y el código HTTP esperado.
  - El flujo no expone datos sensibles como contraseñas o hashes.

REQ-003 — Configurar autenticación post-registro
Definir e implementar en backend el comportamiento de autenticación posterior al registro, dejando listo el contrato para que el frontend reciba el resultado esperado.
Criterios de aceptación:
  - El contrato indica si el registro inicia sesión automáticamente o solo crea la cuenta.
  - Si se emite token, la respuesta lo incluye según el contrato.
  - Si no se emite token, la respuesta lo indica explícitamente y sin ambigüedad.
  - El comportamiento está cubierto por pruebas del backend.
  - No se rompe la compatibilidad con el formato de error compartido.

REQ-004 — Configurar seguridad de origen
Ajustar en backend las reglas de CORS y política de acceso para permitir el consumo desde el frontend acordado sin abrir orígenes innecesarios.
Criterios de aceptación:
  - El backend acepta solicitudes desde el origen del frontend definido para desarrollo.
  - Los orígenes permitidos en producción quedan parametrizados o documentados.
  - Las solicitudes preflight necesarias responden correctamente.
  - No se habilita acceso amplio sin justificación explícita.
  - La configuración queda alineada con el contrato HTTP definido.
</task>
```
