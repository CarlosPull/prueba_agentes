# Memoria del Agente Backend (`dev-back`)

## Aprendizajes del Proyecto Laravel

- **Framework**: Laravel 13 API-first (sin directorio `resources/` ni vistas en el repositorio backend).
- **Rutas**: Se organizan bajo `routes/api.php` con prefijo `v1/`.
- **Estructura**: Dominio orientado a `app/Domain/` y controladores en `app/Http/Controllers/Api/V1/`.
- **Validación Estilo**: Se usa Laravel Pint para formateo de código (`./vendor/bin/pint --test`).
