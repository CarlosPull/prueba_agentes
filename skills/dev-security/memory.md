# Memoria del Agente de Seguridad (`dev-security`)

## Hechos y Decisiones

- **Sanctum & Auth**: Se verifica la autenticación mediante middleware Sanctum en Laravel.
- **Validación de Consultas**: Evitar consultas SQL crudas desprotegidas; usar Eloquent o bindings explícitos.
