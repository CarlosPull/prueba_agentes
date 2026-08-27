# Memoria del Agente Backend (`dev-back`)

## Aprendizajes del Proyecto Laravel

- **Framework**: Laravel 13 API-first (sin directorio `resources/` ni vistas en el repositorio del backend).
- **Rutas**: Se organizan bajo la siguiente estructura de carpetas `routes/api.php` con prefijo `v1/`. 
- **Estructura**: Dominio orientado a `app/Domain/` y controladores en `app/Http/Controllers/Api/V1/`.
- **Validación Estilo**: Se usa Laravel Pint para formateo de código (`./vendor/bin/pint --test`).
