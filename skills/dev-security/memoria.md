# Memoria de Dev Security

## Decisiones tomadas

- [ ] Pendiente: definir criterios específicos de severidad para hallazgos SQL.
- [ ] Pendiente: establecer formato de reporte de auditoría.
- [ ] Pendiente: definir integregación con pipeline de CI/CD.

## Aprendizajes

- Las vulnerabilidades SQL más comunes en Laravel son: `DB::raw()` con variables, `whereRaw()` sin binding, y consultas en archivos de migración con datos sensibles.
