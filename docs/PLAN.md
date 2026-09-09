# Sacrum Gleam — Plan de Implementación

## Visión

Sacrum reescrito en Gleam, embebido, con libsql local (después Turso remoto).
Backend + Tauri GUI. Flujos de control de agentes moldeables y reusables.

## Estado Actual

Proyecto scaffolded con dominio, motor de flujos, y capa DB implementados:
- ✅ Domain: Task, Section, Flow, Execution, Session
- ✅ Flow Engine: validator, executor, engine con builders
- ✅ Database: connection, migrations, tasks/flows/executions CRUD
- ✅ SQL migration 0001_init.sql

Falta compilar (incompatibilidad gleam_json vs gleam_stdlib v1 resuelta).

## Fases

### Fase 1: Foundation (secuencial)
1. **Fix build**: resolver imports, semicolons, JSON encoding manual
2. **Tests unitarios**: domain types, flow validator, flow executor
3. **Migrations runner**: cargar SQL embebido, ejecutar al arranque
4. **Repository layer**: abstracción sobre connection con tipos domain

### Fase 2: API REST (paralelizable tras Fase 1)
5. **Wisp + Mist setup**: servidor HTTP con routing
6. **Tasks API**: CRUD REST para tareas + dependencies
7. **Flows API**: CRUD para templates + instancias
8. **Executions API**: avanzar flujos, reportar resultados, input humano

### Fase 3: Tauri Shell (paralelizable tras Fase 2)
9. **Tauri project**: scaffold + backend Gleam como sidecar
10. **Frontend skeleton**: rutas, layout, state management
11. **Task management UI**: lista, detalle, crear/editar tareas
12. **Flow visualizer**: grafo de flujo interactivo

### Fase 4: Agent Integration (paralelizable)
13. **Harness adapter**: interfaz provider-neutral para agentes (Claude/Codex)
14. **Step executor**: ejecutar agentes, capturar output, reportar métricas
15. **Session logging**: stream de eventos normalizados

### Fase 5: Turso Remote (paralelizable)
16. **Remote connection mode**: URL auth token, sin cambios en lógica
17. **Sync/conflict resolution**: eventual consistency para offline→online

## Diagrama de Dependencias

```
Phase 1 (Foundation)
  ├── [1] Fix build ──→ [2] Tests ──→ [3] Migrations ──→ [4] Repository
  │                                                         │
Phase 2 (API REST)                                          │
  ├── [5] Wisp setup ←──────────────────────────────────────┘
  ├── [6] Tasks API ──→ paralelo ──→ [7] Flows API
  └── [8] Executions API (depende de 6+7)

Phase 3 (Tauri)
  ├── [9] Tauri scaffold (independiente)
  ├── [10] Frontend skeleton (depende de 9)
  ├── [11] Task UI (depende de 10, 6)
  └── [12] Flow visualizer (depende de 10, 7)

Phase 4 (Agents)
  ├── [13] Harness adapter (independiente)
  ├── [14] Step executor (depende de 13, 8)
  └── [15] Session logging (depende de 14)

Phase 5 (Turso)
  └── [16] Remote mode (depende de 4)
```

## Tareas para Issues (con dependencias)

Ver issues del repo. Cada issue tiene:
- Contexto completo del proyecto
- Dependencias (bloquea / es bloqueado por)
- Criterios de aceptación
- Archivos afectados
