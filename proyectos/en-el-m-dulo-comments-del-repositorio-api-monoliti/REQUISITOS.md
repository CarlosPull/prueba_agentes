# Requisitos analizados y enrutados

Solicitud original: En el módulo comments del repositorio api-monolitic-comments, agrega un endpoint GET /api/comments/health que no requiera autenticación y responda JSON con status igual a ok y module igual a comments. Añade una prueba automatizada si la infraestructura del módulo lo permite, valida sintaxis PHP y publica el contrato del nuevo endpoint en la memoria compartida. No modifiques el core ni el módulo posts.

- [REQ-001] **backend** → `backend-core/api-monolitic` (`core`): En el módulo comments del repositorio api-monolitic-comments, agrega un endpoint GET /api/comments/health que no requiera autenticación
- [REQ-002] **general**: responda JSON con status igual a ok
- [REQ-003] **general**: module igual a comments
- [REQ-004] **backend** → `backend-core/api-monolitic` (`core`): Añade una prueba automatizada si la infraestructura del módulo lo permite, valida sintaxis PHP
- [REQ-005] **backend** → `backend-core/api-monolitic` (`core`): publica el contrato del nuevo endpoint en la memoria compartida
- [REQ-006] **general**: No modifiques el core ni el módulo posts
