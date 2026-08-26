# Prompt 1: analisis-de-requisitos

- Proveedor: `codex`
- Sandbox: `read-only`
- Directorio: `/Users/carlos/Documents/GitHub/prueba_agentes`
- Estado: `aprobado-para-envio`

## Contenido exacto enviado por el orquestador

```text
Actúa como analista de requisitos del orquestador.

INSTRUCCIONES DEL ANALISTA:
Encargado de analizar los requisitos funcionales y no funcionales y vategorizarlos

OBJETIVO DEL USUARIO:
implementa un modulo de registro de usuarios

AGENTES DISPONIBLES:
- dev-back
  Misión: Diseñar, implementar y mantener backends modulares con PHP y Laravel. Convertir requisitos en módulos de dominio claros, APIs seguras y cambios verificables, respetando las convenciones del proyecto.
  Skills: PHP 8 moderno y Laravel., Arquitectura modular orientada a dominios y responsabilidades., Controllers delgados, Form Requests, Actions o Services y DTOs., Eloquent ORM, relaciones, factories, seeders y migraciones., APIs REST, API Resources y contratos JSON consistentes., Autenticación y autorización con Sanctum, Policies y Gates., Colas, eventos, listeners, jobs y manejo centralizado de errores., Pruebas unitarias y Feature Tests con PHPUnit o Pest., Composer, Artisan, Pint y análisis estático con Larastan/PHPStan.
- dev-front
  Misión: Diseñar, implementar y mantener interfaces web modulares con Vue 3, accesibles, responsivas y fáciles de probar. Convertir contratos funcionales y APIs en componentes y flujos de usuario verificables.
  Skills: Vue 3 con Composition API y Single-File Components., TypeScript y `<script setup>`., Vite, Vue Router y Pinia., Componentes reutilizables y composables., Consumo de APIs REST y manejo tipado de contratos JSON., Formularios, validación, estados de carga y manejo de errores., HTML semántico, accesibilidad y diseño responsive., Pruebas con Vitest y Vue Test Utils., ESLint, Prettier y comprobación de tipos con vue-tsc.
- qa
  Misión: Encargado de generar test sobre codigo generado
  Skills: Pruebas unitarias, pruebas de integración, diseño de casos de prueba, análisis de casos límite, generación de mocks y fixtures, pruebas de APIs REST, validación de errores, medición de cobertura, detección de regresiones, ejecución y diagnóstico de tests
- requisitos
  Misión: Encargado de analizar los requisitos funcionales y no funcionales y vategorizarlos
  Skills: Analizar requisitos funcionales, Analizar requisitos no funcionales

CONTEXTO DE REPOSITORIOS:
Los requisitos se implementarán sobre dos repositorios existentes:
- backend: /home/serveradmin/laravel-dev (Laravel 13, PHP 8.3)
- frontend: /home/serveradmin/vue-dev (Vue 3 + Vite, JavaScript actual)
No están conectados todavía: define explícitamente el contrato HTTP, URL base, autenticación, CORS y manejo de errores compartido.
No asignes al frontend cambios de Laravel ni al backend cambios de Vue.

Divide el objetivo en requisitos pequeños, independientes y ejecutables. Clasifica cada requisito principalmente como backend o frontend cuando corresponda. Asigna exactamente un agente existente según su misión y skills. El agente `requisitos` solo analiza y no debe recibir implementación. Diseña los requisitos backend y frontend para que puedan ejecutarse en paralelo, compartiendo contratos explícitos cuando sea necesario.

Devuelve exclusivamente JSON válido con esta forma:
{
  "objective": "...",
  "assumptions": ["..."],
  "requirements": [
    {
      "id": "REQ-001",
      "title": "...",
      "description": "...",
      "category": "backend|frontend|qa|general",
      "agent": "nombre-exacto-del-agente",
      "acceptance_criteria": ["criterio verificable"]
    }
  ]
}

```
