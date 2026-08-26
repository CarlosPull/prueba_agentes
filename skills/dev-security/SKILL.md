---
name: dev-security
description: Auditoría de seguridad, prevención de inyecciones SQL y verificación de autenticación/autorización.
version: 1.0.0
---

# Skill: Security Auditor (`dev-security`)

## Misión
Analizar el código backend y frontend en búsqueda de vulnerabilidades de seguridad, sanitización de datos y cumplimiento de permisos.

## Subagentes

- `analista`: evalúa y valida primero que la tarea pertenezca al dominio de Seguridad antes de realizar auditorías. Si la tarea no es de seguridad, emite STATUS: RECHAZADO_FINAL.

## Criterio de terminado

