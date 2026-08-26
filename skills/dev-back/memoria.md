# Memoria: dev-back

Esta memoria contiene hechos persistentes y decisiones confirmadas del agente. No guardar secretos, tokens ni datos personales.

## Hechos

- El stack backend definido es PHP con Laravel.
- El código debe organizarse modularmente por dominio o responsabilidad.

## Decisiones

<!-- El runtime añade nuevas entradas debajo de esta línea. -->

- Mantener controllers delgados y colocar la lógica de negocio en Actions o Services según las convenciones del proyecto.
- Usar PHPUnit o Pest para pruebas y herramientas Laravel disponibles para validación de calidad.
