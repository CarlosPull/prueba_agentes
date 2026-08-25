# Memoria: dev-front

Esta memoria contiene hechos persistentes y decisiones confirmadas del agente. No guardar secretos, tokens ni datos personales.

## Hechos

- El stack frontend definido es Vue 3 con Composition API.
- Se utilizará TypeScript y componentes `.vue` modulares.

## Decisiones

<!-- El runtime añade nuevas entradas debajo de esta línea. -->

- Preferir `<script setup>`, composables para lógica reutilizable y Pinia únicamente para estado compartido.
- Validar componentes con Vitest, Vue Test Utils y vue-tsc cuando estén disponibles.
