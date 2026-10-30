# Object Dependency Ordering

This reference documents the deterministic ordering that `sqlmig build` applies to the **REPEATABLE** migration (R__) (`Build-SqlMigRepeatable` in `scripts/SqlMigration.Core.ps1`).

## Why ordering matters

Flyway runs each migration script top to bottom, one `GO`-separated batch at a time. When two new objects in the same R__ migration have a **referential dependency** — e.g., a stored procedure that calls a new view — the dependency target **must be created first**.

SQL Server's deferred-name-resolution **masks** this for stored procedures: `CREATE PROCEDURE` succeeds even if the referenced view doesn't exist yet. The error appears later, on first execution (`Invalid object name 'cc.vwOrderTotal'`). Views, functions, and inline-table-valued functions, on the other hand, **must** be created in dependency order — `CREATE VIEW` resolves names eagerly.

The default alphabetical sort (Stored Procedures `S` < Views `V`) emits SPs **before** views, which is exactly backwards.

## Algorithm

For every changed file under `Views/`, `Stored Procedures/`, `Functions/`, or `Triggers/`, and every changed `Tables/`, `Synonyms/`, `Security/` or `User Defined Types/` file with object-level grants or, for a table, a trigger defined in the file:

1. **Identify the defined object.** A view, procedure, function or trigger file is named by its own `CREATE` statement (an unqualified name is `dbo`), with the path `<schema>/<ObjectType>/<Name>.sql` as the fallback, since a file can sit in another schema's folder. A table, synonym, security or UDT file is named by its path.
2. **Strip comments** from what the object puts in the R__ (`-- single-line` and `/* … */` block comments) so a comment that mentions another object isn't treated as a real reference. A table file puts only its grants and triggers there, and only its triggers can reference other objects.
3. **Find references** to other defined identifiers in the same set, using these patterns (case-insensitive), anchored with lookarounds rather than `\b` (which never matches next to a bracket):
   - `schema.Name`
   - `[schema].[Name]`
   - `[schema].Name`
   - `schema.[Name]`
4. **Build a directed graph**: an edge from A → B means "A references B" (A depends on B and must be emitted *after* B). A table is never a target: nothing has to be created after a table's grants or triggers.
5. **Order the strongly connected components** (Tarjan) topologically (Kahn), so every edge between components is respected, with these tie-breakers when no edge constrains order:
   - **Tier 1**: Functions (referenced by views, SPs, triggers)
   - **Tier 2**: Views (referenced by SPs, triggers, other views via tier-1 edges)
   - **Tier 3**: Stored Procedures
   - **Tier 4**: Triggers (typically reference tables in the V__ migration; emitted last so any view/SP they reference is already defined), and the grants and triggers taken from table, synonym, security and UDT files
   - **Inside a tier**: alphabetical by `schema.Name`
6. **Cycle handling**: a cycle (procedures that call each other, say) is one component. Inside it only **must-precede** edges are enforced — a view or function after the views and functions it names, a function before anything that calls it — then tier and name; what a procedure or trigger references is resolved at run time, so the rest can go in any order. Views/functions that name each other in a loop cannot all be satisfied: the build warns, and the order check below fails.
7. **Self-checks**: the build stops without writing the R__ if an object was lost or duplicated, a must-precede edge points forward, or a batch is not re-runnable (anything but `CREATE OR ALTER`, `DROP … IF EXISTS`, `GRANT`/`REVOKE`/`DENY`, `SET`).

Objects the **V__ drops** come back through the R__: before each `DROP TYPE`, the build drops whatever referenced the type at the merge base, and every procedure, function, view or trigger the V__ drops that still exists in source is added to the R__.

## What the build scans

The build does **not** parse SQL: it pattern-matches names in a view of the text with comments and string literals blanked. Dynamic SQL inside `EXEC('...')` or `sp_executesql N'...'` is kept, because it runs. A name that still matches by accident creates an unnecessary edge, never a wrong one, and the topological sort still produces a valid order.

References to objects **not in the changed file set** (i.e., already-deployed objects) are ignored — they're already in the database when Flyway runs the R__ migration.

## The order check

`sqlmig check` verifies both final scripts, however they were produced, with comments and string literals masked. Dynamic SQL in `EXEC(...)`/`sp_executesql` is kept, since it runs. It exits 1 when:

- **R__**: a batch cannot be re-run; a view or function comes before a view or function it names, or before a function it calls; the script drops an object it created.
- **V__**: a table, type, synonym, sequence, schema or role is used before it is created, or after it is dropped; a foreign key on an existing table is added before the lookup table it references is seeded (error 547 on populated environments; a warning for new nullable columns); a plain `CREATE` of a view, procedure, function or trigger that already exists, or an unguarded `CREATE` of a table, type, synonym or sequence that already exists, unless the script dropped it first; a column used before the `ALTER TABLE … ADD` that adds it, or by DML later in the same batch (SQL Server compiles the batch before the `ALTER` runs; DDL later in the batch and dynamic SQL are fine); a `DROP TYPE` while something still references the type; a `DROP TABLE` while another table's foreign key still references it; a repeatable object dropped and not re-created by the R__.
- **Across the two** (the V__ runs first): the V__ uses an object this branch adds in the R__; an R__ view or function references what the V__ drops.
- **Either script**: a `$(Variable)` SQLCMD token is still in it.

It warns, without failing, when an `ONLINE = ON` index follows an `ALTER TABLE` of the same table in one versioned script (see `references/index-standards.md`).

## What the build does NOT do

- It does not reorder the **VERSION (V__) migration**. V__ ordering is described in `SKILL.md` (Object Ordering → "VERSION migration (V__)") and produced by Claude; the order check above verifies it.
- It does not detect **cross-database dependencies**: synonyms point at other databases whose objects it cannot see. Those are runtime concerns; the build only maps the SQLCMD variables that name those databases.
- It does not enforce **trigger-after-table** ordering — triggers live in R__ but reference tables in V__. Flyway runs V__ before R__ in the same migration set, so the table is always there.

## Example

A branch adds three files, all under schema `cc`:

| Path | Object |
|---|---|
| `AppDb/cc/Functions/fnOrderTax.sql` | `cc.fnOrderTax` |
| `AppDb/cc/Stored Procedures/spReportOrders.sql` | `cc.spReportOrders` (calls `cc.vwOrderTotal`, uses `cc.fnOrderTax` in a column) |
| `AppDb/cc/Views/vwOrderTotal.sql` | `cc.vwOrderTotal` (uses `cc.fnOrderTax`) |

**Old ordering** (alphabetical by path): `Functions/fnOrderTax` → `Stored Procedures/spReportOrders` → `Views/vwOrderTotal`. SP is emitted before its view dependency. Deferred name resolution lets the SP CREATE succeed, but `cc.vwOrderTotal` does not exist yet at that point. Nothing fails until the first caller of `spReportOrders` hits `Invalid object name 'cc.vwOrderTotal'` before the view is created.

**New ordering**:
1. Edges: `vwOrderTotal → fnOrderTax`, `spReportOrders → vwOrderTotal`, `spReportOrders → fnOrderTax`
2. Topological sort: `fnOrderTax`, `vwOrderTotal`, `spReportOrders`
3. Tier check: `fnOrderTax` (tier 1) → `vwOrderTotal` (tier 2) → `spReportOrders` (tier 3) — already correct.
4. Emit in that order.

## Diagnostics

`sqlmig build` prints the emit order and every inferred dependency edge (`a -> b`: a needs b first). Read them to spot an accidental cycle or a wrongly identified object before the migration runs anywhere.
