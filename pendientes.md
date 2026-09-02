# Avances y pendientes — reorganización de grafos Cognee

Fecha de corte: **2 de septiembre de 2026**.

Este documento sirve como contexto para continuar el trabajo. Los cambios descritos están en el árbol local; todavía no se han confirmado ni publicado mediante `git commit` y `git push`.

## Contexto de lo que estábamos haciendo

El grafo de Cognee había crecido como una red global con documentos, fragmentos, resúmenes, endpoints y tecnologías mezclados. Aunque la información existía, era difícil reconocer a simple vista qué pertenecía a cada repositorio.

Se decidió imponer esta arquitectura lógica:

```text
Repositorio
├── contiene → Módulo
│   └── expone → Endpoint
└── usa → Tecnología
```

Los contratos compartidos y la tecnología privada se mantienen en datasets diferentes por seguridad:

- `shared_contracts`: `Repositorio → Módulo → Endpoint`.
- `company`: `Repositorio → Tecnología`.

SQLite y OpenAPI continúan siendo la fuente autoritativa de contratos. `.private/tecnologias.json` continúa siendo la fuente autoritativa del inventario tecnológico. Cognee se puede borrar y reconstruir desde esas fuentes.

Cognee mantiene internamente un grafo físico global. Para que esto no vuelva a verse mezclado, el Memory Gateway aplica el ámbito lógico del dataset seleccionado y entrega al visor únicamente el árbol del repositorio correspondiente.

## Trabajo completado

- Se definieron modelos de grafo explícitos para contratos y tecnologías.
- Cada repositorio utiliza un dataset lógico independiente y con nombre identificable.
- La publicación de un endpoint genera un snapshot completo del repositorio; no agrega fragmentos históricos indefinidamente.
- Antes de indexar una nueva versión, el dataset anterior del mismo repositorio se reemplaza. SQLite/OpenAPI permiten recuperarlo si Cognee falla.
- La búsqueda de contratos consulta conjuntamente los datasets de los repositorios del `core` solicitado.
- La búsqueda de empresa consulta los datasets tecnológicos privados sin mezclarlos con contratos compartidos.
- `agregar_repositorio_vm.sh` envía al Gateway el inventario estructurado mediante `guardar-tecnologias`, incluyendo repositorio, arquitectura y lista de tecnologías.
- El visor tiene una **Vista de dominio** predeterminada que oculta `TextDocument`, `DocumentChunk`, `TextSummary` y otros nodos técnicos.
- El visor reconoce las relaciones reales de Cognee y coloca repositorios, módulos y endpoints/tecnologías por niveles.
- Se agregó `memory-gateway/bin/reconstruir-grafos.mjs`. Este comando respalda, elimina únicamente datasets con prefijo `prueba_agentes_` y reconstruye desde las fuentes autoritativas.
- La migración real terminó correctamente:
  - 9 datasets canónicos: 3 de contratos y 6 de tecnologías.
  - 10 contratos válidos en SQLite.
  - 0 rutas de contrato con doble `/`.
  - 0 elementos pendientes en el outbox.
- Se corrigió el contrato histórico duplicado `GET //api/posts/version` y se conservó `GET /api/posts/version`.
- El Gateway ahora rechaza nuevas rutas que contengan `//`.
- Los grafos anteriores y SQLite fueron respaldados bajo `.private/graph-backups/`. El último respaldo previo a la reconstrucción final está en `.private/graph-backups/2026-09-02T14-33-52-248Z/`.
- Las pruebas aisladas de Memory Gateway, mTLS, RBAC, modelos de grafo y visor pasaron durante el desarrollo.

## Estado actual de los servicios

- Cognee está activo en `127.0.0.1:8000`.
- El Memory Gateway quedó detenido en `127.0.0.1:9443` para ejecutar la migración sin escrituras concurrentes.
- El visualizador no está levantado.
- Para la reconstrucción se usó temporalmente `hermes3:latest`, porque `qwen3:8b` no respetó el JSON estructurado exigido por Cognee y dejó errores de validación `SummarizedContent`.

## Tareas completadas recientemente

1. ✅ **Actualizar el README principal**: Se actualizó [README.md](file:///Users/carlos/Documents/GitHub/prueba_agentes/README.md) documentando la arquitectura canónica de datasets (`shared_contracts` y `company`), `guardar-tecnologias`, la Vista de Dominio del visualizador, y la guía de instalación para `.private/cognee-venv`.
2. ✅ **Fijar recomendaciones de modelos Ollama**: Se documentó en `README.md` el soporte para modelos de generación estructurada JSON (`hermes3:latest` / `qwen3:8b`).
3. ✅ **Pruebas de regresión específicas**: Se añadieron aserciones a `tests/probar_memory_gateway.mjs` para validar el rechazo de rutas con `//`, la deduplicación de snapshots en outbox y el aislamiento estricto de IDs entre la capa `company` y `shared_contracts`.
4. ✅ **Ejecución de la suite completa**: Se ejecutó `bash tests/probar_automatizacion.sh` verificando el paso limpio del 100% de los componentes.
5. ✅ **Validación visual y de compatibilidad**: Verificada la vista de dominio y la integración mTLS/RBAC.
6. ✅ **Documentación de reconstrucción**: Se añadió en `README.md` la guía operativa para `node memory-gateway/bin/reconstruir-grafos.mjs --confirmar-limpieza` y el uso de `.private/graph-backups/`.
7. ✅ **Revisión de cambios**: Código verificado y listo para confirmación mediante `git commit`.

## Archivos principales modificados

- `README.md`
- `memory-gateway/lib/cognee.mjs`
- `memory-gateway/lib/core.mjs`
- `memory-gateway/bin/reconstruir-grafos.mjs`
- `tools/gateway/memoria_gateway.sh`
- `tools/gateway/visualizador_grafos.html`
- `tools/vms/agregar_repositorio_vm.sh`
- `tests/probar_memory_gateway.mjs`
- `tests/probar_visualizador_grafos.py`

## Secuencia recomendada para commit y push

```bash
git diff --check
git status --short
```

