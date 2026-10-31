# ZIBP_PDS_COPY_LOGSYS

Copies IBP source-of-supply (PDS) data from one logical system to another:

- **Reads** from `/IBP/SOSHEAD_EXT`, `/IBP/SOSBOM_EXT`, `/IBP/SOSACT_EXT`
  where `LOGSYS = 'EDI'` (source, configurable on the selection screen).
- **Deletes** the existing `LOGSYS = 'TDS'` rows in each table first.
- **Inserts** copies carrying `LOGSYS = 'TDS'` (target, configurable).
- **Parallelises** the inserts across free work processes with the **SPBT**
  framework to shorten the runtime.

## Objects

| Object | Type | File |
|--------|------|------|
| `ZIBP_PDS_COPY_LOGSYS` | Executable program (report) | `zibp_pds_copy_logsys.prog.abap` |
| `Z_IBP_PDS_COPY_LOGSYS_PAR` | RFC function module (worker) | `z_ibp_pds_copy_logsys_par.abap` |

Create the function module inside a function group (e.g. `ZIBP_PDS`) in SE37
and tick **Remote-Enabled Module** on the *Attributes* tab — SPBT dispatches
it via `CALL FUNCTION ... STARTING NEW TASK ... DESTINATION IN GROUP`, which
only works with remote-enabled modules.

## Selection screen

| Field | Meaning | Default |
|-------|---------|---------|
| `P_SRC` | Source logical system to read | `EDI` |
| `P_TGT` | Target logical system to write | `TDS` |
| `P_GROUP` | RFC server group for SPBT | `parallel_generators` |
| `P_PKG` | Rows per parallel package | `5000` |
| `P_TEST` | Test run — counts only, no DB change | off |

The RFC server group (`P_GROUP`) must exist in transaction **RZ12**. Replace
the default if your system uses a different group for parallel RFC.

## How the parallel split works

`LOGSYS` is part of the primary key of all three tables, so a source row and
its `TDS` copy have different keys — flipping `LOGSYS` and inserting produces
no key clash once the stale `TDS` rows are deleted.

Because every row is transformed independently (overwrite `LOGSYS`, insert —
no joins), the report reads each table in packages (`SELECT ... PACKAGE SIZE`)
and hands each package to a free work process. Each worker runs in its own LUW
and commits its own package. The deletes happen once, up front, and are
committed before any task starts.

## Assumptions to verify in your system

- The logical-system column is named `LOGSYS` in all three tables. If it
  differs, adjust the `WHERE` clauses, the worker's field overwrite, and the
  structure references.
- The caller (report) and the workers run on the same DB, so the up-front
  delete + committed inserts are visible consistently.
  test readme
