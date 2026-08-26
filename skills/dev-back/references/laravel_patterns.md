# Patrones de Referencia Laravel

## Respuestas JSON de API

```json
{
  "data": { ... },
  "message": "Operación exitosa",
  "status": "success"
}
```

## Form Requests
Toda validación de entrada debe realizarse en un Form Request derivado de `Illuminate\Foundation\Http\FormRequest`.
