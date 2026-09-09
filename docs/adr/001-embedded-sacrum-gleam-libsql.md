# ADR-001: Embedded Sacrum en Gleam con libsql/Turso

## Status
Proposed

## Context

Sacrum actual es un servidor Elixir/Phoenix con PostgreSQL, GraphQL API y Phoenix Channels.
Vertebrae (Rust) actúa como cliente con CLI, GUI Tauri y daemon.

**Problema:** La arquitectura requiere un servidor remoto siempre disponible. Para uso
embedded/local-first con migración posterior a Turso (acceso remoto), necesitamos un
backend autocontenido.

**Requerimientos del usuario:**
- Tauri + Gleam (no Rust backend + React frontend)
- Backend embedded en Gleam
- libsql local → Turso remoto (misma API)
- Flujos de control de agentes moldeables y reusables
- Distintos tipos de flujo: con loops, sin loops, con inputs humanos entre pasos
- Al asignar una tarea a un agente, poder elegir qué tipo de flujo usar
- Emular la funcionalidad de Sacrum (workflow engine, task management, execution tracking)

## Decision

### Stack
| Capa | Tecnología | Rationale |
|---|---|---|
| Backend | **Gleam** (BEAM) | Tipado estático, concurrencia OTP, interoperabilidad Erlang |
| HTTP Server | **Mist** | Servidor HTTP nativo para Gleam |
| Web Framework | **Wisp** | Framework web práctico para Gleam |
| Database | **libsql_gleam** (NIF Rust) | SQLite local → Turso remoto sin cambiar código |
| Frontend GUI | **Tauri** (TBD) | Shell nativo, WebView para UI |
| Frontend Web | **Lustre** (TBD) | Framework UI en Gleam si se necesita SPA |

### Arquitectura de Flujos Moldeables

Los flujos se modelan como **grafos dirigidos de nodos composables**:

```
FlowTemplate (definición reutilizable)
  └── Node (tipo determina comportamiento)
        ├── Step          → Ejecuta agente con prompt/config
        ├── Sequence      → Ejecuta hijos en orden
        ├── Branch        → Evalúa condiciones, elige target
        ├── Loop          → Repite hijos hasta condición de salida
        ├── Parallel      → Ejecuta hijos concurrentemente
        └── HumanInput    → Pausa, espera input externo
  └── Transition (con condición opcional)
```

**Mecanismo de ejecución:**
1. `FlowTemplate` se valida (DAG, refs, ciclos)
2. Se instancia como `FlowInstance` vinculada a un `Task`
3. `ExecutionState` sigue el grafo nodo a nodo
4. Cada `advance()` devuelve `(nuevo_estado, acción_a_ejecutar)`
5. El caller ejecuta la acción (agent prompt, input humano, etc.) y reporta resultado

**Patrones predefinidos:**
- `build_linear_flow()`: paso1 → paso2 → paso3
- `build_loop_flow()`: pre → loop(condición) → post
- `build_branch_flow()`: paso → branch(condiciones) → ramificaciones

### Persistencia

```
Local:    libsql file:sacrum.db (mismo proceso)
Remoto:   libsql libsql://db.turso.io (sin cambiar código)
```

Migraciones SQL embebidas en el binario para despliegue sin filesystem.

## Consequences

### Positivas
- **Zero-config local**: un binario con DB embebida
- **Migración transparente**: mismo código para local y remoto
- **Flujos reusables**: las plantillas de flujo son composables
- **Tipado fuerte**: Gleam detecta errores en compilación
- **Concurrencia OTP**: el executor es puramente funcional, fácil de paralelizar

### Negativas
- **Ecosistema joven**: menos librerías que Rust/Elixir
- **libsql_gleam**: NIF no oficial, depende de mantenimiento externo
- **JSON**: sin biblioteca madura (gleam_json incompatible con stdlib v1)
- **Curva aprendizaje**: Gleam es menos conocido que Rust/Elixir

### Riesgos mitigables
- JSON manual → usar `gleam_experimental` o wrapper propio
- libsql_gleam → mantener capa de abstracción para swap si necesario
- HTTP en Gleam → Wisp/Mist son estables pero jóvenes

## Alternativas consideradas

### A) Mantener Sacrum Elixir + Vertebrae Rust
- Pros: maduro, probado
- Contras: no embedded, requiere servidor separado

### B) Tauri + Rust backend (actual crates/local-backend/)
- Pros: mismo ecosistema que Vertebrae
- Contras: no BEAM/OTP, menos natural para workflows stateful

### C) Gleam + PostgreSQL
- Pros: compatible con Sacrum actual
- Contras: no embedded, pierde la ventaja local-first
