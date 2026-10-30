---
name: sql-migration-generator
description: Generate Flyway migration scripts for SQL Server - a versioned V__ script for tables, indexes, keys, synonyms, types and reference data, and a repeatable R__ script for views, procedures, functions and triggers - from the changes on an SSDT database project branch, then check the object order. Use when asked to generate, regenerate, fix or check migration scripts, a Flyway migration, or V__/R__ scripts for a .sqlproj database.
---

# SQL Migration Generator

You generate Flyway-compatible migration scripts for the `{{DATABASE}}` SQL Server database
from the changes on one branch of its SSDT project: one versioned script (V__) and one
repeatable script (R__) per branch.

<!-- interactive:begin -->
## Running it in Claude Code

(If this text reached you as a one-shot prompt whose **Changed Files** section at the end
already holds JSON, skip this section and answer in the Output Format.)

`sqlmig` below means `pwsh <this skill's folder>/scripts/sqlmig.ps1`, run from inside the
database repository (PowerShell 7 and git). The scripts do everything that can be done
deterministically. You write the versioned script; the script builds the repeatable script
from the source files. In this mode the `{{...}}` placeholders in this file are not filled
in: take their values from the context file (`date`, `database`, `branchSlug`, `nextVersion`).

1. **Configure once.** If the repository root has no `migration.config.json`, run
   `sqlmig init`, show the user the file, and have them confirm `database`, `ciRole` and
   every `sqlcmdVariables` value before you go on. A wrong database name lands in every
   synonym and three-part name. If the config exists, run `sqlmig init -Check` and resolve
   each ERROR before generating.
2. **Context.** Run `sqlmig context -RemoveExisting`. Use `-CommittedOnly` only if the user
   wants to match CI; by default uncommitted changes count. Then read the JSON file it
   prints. If it reports `Kept ... uncommitted edits`, ask the user before re-running with
   `-Force`: those edits would be lost. If nothing changed, say so and stop.
3. **Write the versioned script**, if the rules below call for one, to the context's
   `versionFile`. Work from `changes` (each entry has `Status`, `Kind`, `Content`, and `Diff`
   for modified files). Write only the SQL, with no XML envelope. **Never write the
   repeatable script**: step 4 builds it.
4. **`sqlmig build`** finishes the versioned script. It moves object-level grants out,
   replaces `$(Variable)` tokens, and drops whatever references a type before a
   `DROP TYPE`. It then builds the repeatable script in dependency order. Exit 1 means a
   SQLCMD variable has no mapping: add it to `sqlcmdVariables` and repeat.
5. **`sqlmig check`** verifies the object order of both scripts.
   - Exit 0: the check passed. Read its warnings anyway.
   - Exit 1: fix the versioned script, then repeat from step 4. If the error is in the
     repeatable script, fix the source file instead of editing that script. Stop after
     three rounds and report what is left.
   - Exit 3: the check could not run. Report that; it is not a pass.
6. **Review** both files against `references/migration-review.md`: syntax per batch,
   references to objects that exist nowhere, and grants. Report what you find, most severe
   first.
7. If the branch adds a schema folder or new files, run `sqlmig project` (a dry run). If
   the user agrees, run `sqlmig project -Apply` to add the deploy-role grants and the
   `.sqlproj` items.
8. **Report** the two file paths, one line per object each script touches, every warning,
   and anything the user has to decide. Do not commit unless asked.

To run the generation with any other model, use `sqlmig prompt` to write a one-shot prompt.
Save the model's reply and run `sqlmig apply -ResponseFile <reply>`, then do steps 4-6.
<!-- interactive:end -->

## Migration Type Rules

There are two types of migration scripts:

### Repeatable Migrations (R__)
- **For**: Views, Stored Procedures, Functions, Triggers
- **Filename**: `R__{{DATE}}.{{DATABASE}}.{{BRANCH_NAME}}.sql`
- **Syntax**: MUST use `CREATE OR ALTER` (never plain `CREATE`, never `DROP and CREATE`)
- **Permissions**: Object-level GRANTs (`GRANT ... ON OBJECT::`) belong here
- The date leads the name on purpose: Flyway runs repeatable scripts in name order after
  all versioned ones, so on a fresh database a later branch's definition of an object
  replaces an earlier one's.

### Version Migrations (V__)
- **For**: Tables, Indexes, Foreign Keys, Synonyms, UDTs, Sequences, Constraints, Reference
  Data, Roles, and DELETED structural objects. That last group means Tables, Synonyms and
  UDTs only. Deleted Views, Stored Procedures, Functions and Triggers are dropped in the
  R__ migration.
- **Filename**: `{{NEXT_VERSION}}__{{DATE}}.{{DATABASE}}.{{BRANCH_NAME}}.sql`
- **Syntax**: ALL objects MUST be wrapped in idempotent `IF EXISTS`/`IF NOT EXISTS` patterns with `BEGIN`/`END` + `GO` blocks
- **Permissions**: ONLY schema-level GRANTs (`GRANT ... ON SCHEMA::`) for new schemas

## SQL Syntax Rules

For VERSION migrations, you MUST ensure:

1. **PRIMARY KEY required**: All `CREATE TABLE` statements must have a PRIMARY KEY defined
2. **BEGIN/END matching**: Every `BEGIN` must have a matching `END`
3. **GO separators**: Use `GO` to separate batches. It is required whenever there is more than one DDL/DML statement.
4. **Valid data types**: All data types must be valid SQL Server types with length/precision specified (no bare `VARCHAR()` or `NVARCHAR()`)
5. **NULL/NOT NULL**: All columns must have explicit NULL/NOT NULL specifications
6. **Foreign keys**: Add FOREIGN KEY constraints when referencing other tables; references must target existing tables/columns
7. **Index names**: Must be unique and follow naming conventions (IX_, PK_, UQ_, etc.)
8. **Trigger NULL handling**: Use COALESCE or ISNULL when inserting from INSERTED into NOT NULL columns
9. **Execution order**: schema → GRANT schema permissions to the deploy role → UDTs → tables → lookup/parent seeds → constraints → indexes → FKs → synonyms → data inserts and backfills (see "VERSION migration (V__)" under Object Ordering). Triggers go in the repeatable migration, never here.

## Permission Placement Rules

- **Object-level GRANTs** (`GRANT EXECUTE/SELECT ON OBJECT::schema.ObjectName`) go ONLY in the REPEATABLE migration (R__), NEVER in version migration (V__)
- **Schema-level GRANTs** (`GRANT ... ON SCHEMA::`) for new schemas go in the VERSION migration (V__)
- If the ONLY content for a version migration would be object-level GRANTs, do NOT generate a VERSION_MIGRATION section at all
- If the ONLY content for a version migration would be DROPs of repeatable objects (Views, Stored Procedures, Functions, Triggers), do NOT generate a VERSION_MIGRATION section at all. The build step emits those drops into the R__ migration itself.
- **The deploy role's own file** (Kind `ci-role` in the changed files; `ciRoleFile` in the Repository Configuration) never goes into a migration. Its grants refer to the role itself, so the deploy login cannot apply them; it is managed out of band.

## SQLCMD Variable Replacement

SSDT synonyms and cross-database references name other databases through SQLCMD variables. Replace each one with the real database name:
- **Source format**: `FOR [$(VariableName)].schema.object`
- **Migration format**: `FOR ActualDatabaseName.schema.object`
- Remove the brackets and `$()` syntax and use the plain database name. Keep brackets only if the name is not a regular identifier (it contains a hyphen or a space, say).

The variable-to-database mapping is the **SQLCMD Variable Mappings** table in the Repository Configuration. In Claude Code it is `sqlcmdVariables` in `migration.config.json`. The replacement MUST be case-insensitive.

**CRITICAL**: a variable can map to a database whose name differs from the variable's (for example `$(Catalog)` → `AppCatalog`). Use the table, and never assume the literal name. A variable missing from the table is an error to report, not a name to guess.

## New Schema Detection

When new tables/objects use a schema not already in the database, add at the START of the VERSION migration.

**CRITICAL — How to determine if a schema already exists:**
A schema already exists if ANY of these are true:
1. The changed file's path contains an existing schema subdirectory. For example, `Sales/sales/Tables/...` with status `M` means `sales` exists.
2. Other changed files in the same branch use the same schema with status `M` (modified = schema exists)
3. The schema is a well-known database schema (dbo, sys, etc.)
4. The schema is listed under **Schemas** in the Repository Configuration and no changed `Security/` file creates it

**DO NOT** generate CREATE SCHEMA or GRANT statements for schemas that already exist. This causes redundant GRANTs in production and clutters migration scripts.

**Only for truly NEW schemas** (an added `CREATE SCHEMA` file, or a schema subdirectory that is new on this branch), add:

1. `IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name='<schema>') BEGIN EXEC('CREATE SCHEMA [<schema>] AUTHORIZATION [dbo]'); END`
2. `GO`
3. Then IMMEDIATELY add GRANT permissions for the deploy role. Write one per line, each followed by `GO`. Below, `<ciRole>` is the configured role, for example `role_app_ci`:
   ```sql
   GRANT ALTER ON SCHEMA::[<schema>] TO [<ciRole>];
   GO
   GRANT SELECT ON SCHEMA::[<schema>] TO [<ciRole>];
   GO
   GRANT INSERT ON SCHEMA::[<schema>] TO [<ciRole>];
   GO
   GRANT UPDATE ON SCHEMA::[<schema>] TO [<ciRole>];
   GO
   GRANT DELETE ON SCHEMA::[<schema>] TO [<ciRole>];
   GO
   GRANT EXECUTE ON SCHEMA::[<schema>] TO [<ciRole>];
   GO
   GRANT REFERENCES ON SCHEMA::[<schema>] TO [<ciRole>];
   GO
   ```

GRANTs MUST come BEFORE any CREATE TABLE/objects in that schema; deployment WILL FAIL without them. Do not warn: just create them. If the Repository Configuration names no deploy role, emit the `CREATE SCHEMA` without grants and say so in the summary.

New schema object order: 1)CREATE SCHEMA 2)GRANT schema permissions to the deploy role 3)UDTs 4)CREATE TABLE 5)lookup/parent seeds 6)constraints 7)indexes 8)FKs 9)synonyms 10)data inserts. Triggers go in the repeatable migration.

## Modified Files (Status M)

For MODIFIED table/structure files, analyze the **Diff field** (not the Content field) to determine what actually changed. The object ALREADY EXISTS in the database — NEVER recreate it. Generate ONLY the specific ALTER/DROP/ADD operations for the delta:

- FK removed in diff → `IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_Name') BEGIN ALTER TABLE [s].[t] DROP CONSTRAINT [FK_Name]; END GO`
- FK added in diff → `IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_Name') BEGIN ALTER TABLE [s].[t] ADD CONSTRAINT [FK_Name] FOREIGN KEY (...) REFERENCES ...; END GO`
- UQ/PK removed → `IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name='UQ_Name') BEGIN ALTER TABLE [s].[t] DROP CONSTRAINT [UQ_Name]; END GO`
- UQ/PK added → `IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name='UQ_Name') BEGIN ALTER TABLE [s].[t] ADD CONSTRAINT [UQ_Name] UNIQUE(...); END GO`
- CK removed → `IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name='CK_Name' AND parent_object_id=OBJECT_ID('[s].[t]')) BEGIN ALTER TABLE [s].[t] DROP CONSTRAINT [CK_Name]; END GO`
- DF removed → `IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name='DF_Name' AND parent_object_id=OBJECT_ID('[s].[t]')) BEGIN ALTER TABLE [s].[t] DROP CONSTRAINT [DF_Name]; END GO`
- DF added → `IF NOT EXISTS (SELECT 1 FROM sys.default_constraints WHERE name='DF_Name' AND parent_object_id=OBJECT_ID('[s].[t]')) BEGIN ALTER TABLE [s].[t] ADD CONSTRAINT [DF_Name] DEFAULT (val) FOR [col]; END GO`
- Column added → `IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE name='col' AND object_id=OBJECT_ID('[s].[t]')) BEGIN ALTER TABLE [s].[t] ADD [col] datatype; END GO`
- Column removed → `IF EXISTS (SELECT 1 FROM sys.columns WHERE name='col' AND object_id=OBJECT_ID('[s].[t]')) BEGIN ALTER TABLE [s].[t] DROP COLUMN [col]; END GO` (drop dependent constraints first)
- Column type/nullability changed → ALTER COLUMN with 3-step constraint handling (see `references/column-modification.md`)
- Index added/removed → CREATE/DROP INDEX with IF EXISTS/IF NOT EXISTS pattern
- Modified Synonyms → IF EXISTS DROP + IF NOT EXISTS CREATE (synonyms do not support ALTER)
- Modified UDTs → drop dependent objects first, DROP TYPE, then CREATE TYPE. The build step also drops, before your DROP TYPE, whatever referenced the type, and re-creates it in the repeatable migration.

**CRITICAL — enumerate every column, never generate it at run time**: emit ONE literal, individually guarded `IF EXISTS … DROP COLUMN … END GO` block per removed column, naming that column. The same applies to `ADD` and `ALTER COLUMN`. This holds **no matter how many columns are involved**: 300 dropped columns means 300 literal blocks. NEVER substitute:

- a cursor, `WHILE` loop, or any iteration over `sys.columns`;
- a "keep list" table variable anti-joined against `sys.columns` to derive the drops;
- a `DROP COLUMN a, b, c` comma list (one failure aborts every column in the statement);
- `EXEC`/`sp_executesql` over a concatenated `nvarchar(max)` of DDL.

A wide-table rebuild is exactly when this shortcut is most tempting and most damaging. A drop derived at run time cannot be reviewed: what it does depends on the live catalog, not on the script. Every statement lands in ONE batch, so a single failure aborts the rest and leaves the table in an arbitrary partial state. Later migrations are diffed against the **source file**, so any column the batch failed to drop is never seen again. It becomes permanent schema drift that an SSDT publish would try to drop. If the enumeration makes the script long, the script is long, and that is the correct output.

NEVER use CREATE TABLE for modified table files. The diff lines starting with `-` are removals, `+` are additions. Focus exclusively on those changes.

## New Files (Status A)

Use the full `IF NOT EXISTS` → `CREATE TABLE` pattern. The table does NOT exist yet.

## Deleted Files Handling

- **Tables**: Scan the deleted file for an embedded CREATE TRIGGER. DROP order: 1)triggers 2)table. Use IF EXISTS.
- **Stored Procedures, Views, Functions, Triggers**: no DROP in VERSION. The repeatable migration drops them.
- **Synonyms**: VERSION with DROP + IF EXISTS.
- Example:
  ```sql
  IF EXISTS (SELECT 1 FROM sys.triggers WHERE name='X') DROP TRIGGER [s].[X];
  GO
  IF EXISTS (SELECT 1 FROM sys.objects WHERE object_id=OBJECT_ID(N'[s].[T]') AND type='U') DROP TABLE [s].[T];
  GO
  ```

## ALTER COLUMN

3 steps: 1) DROP dependent constraints/indexes (IF EXISTS + GO) 2) ALTER COLUMN (GO) 3) RECREATE (IF NOT EXISTS + GO).
Check sys.key_constraints, sys.default_constraints, sys.check_constraints, sys.indexes, sys.foreign_keys.
See `references/column-modification.md` for detailed patterns.

## Idempotent Patterns

ALL Version migration objects MUST use idempotent patterns. See `references/idempotent-patterns.md` for the complete catalog.

## Object Ordering

### REPEATABLE migration (R__) — built deterministically

The build step (`sqlmig build`) builds the R__ from the changed source files. It sorts views, procedures, functions and triggers topologically by their actual references to each other. Ties break in this order: **Functions → Views → Stored Procedures → Triggers**, alphabetical within each tier.

So **you do NOT need to think about R__ ordering**. Emit your `<REPEATABLE_MIGRATION>` content as a single block in any order, or omit it; the build step replaces it. It works from references between files (`schema.Name`, `[schema].[Name]`) and ignores comments and string literals, so a `-- references cc.vwOrderTotal` line does not count.

See `references/dependency-ordering.md` for the full algorithm and an example.

### VERSION migration (V__) — your responsibility

For V__ migrations the order is fixed and you must emit objects in this sequence:

1. `IF NOT EXISTS … CREATE SCHEMA` (only for genuinely new schemas)
2. Schema-level GRANTs to the deploy role
3. User-Defined Types (UDTs)
4. `CREATE TABLE` (and inline PK constraints)
5. **Lookup/parent reference-data seeds.** Seed a lookup or parent table (idempotently: per-row `IF NOT EXISTS` / `WHERE NOT EXISTS`) IMMEDIATELY after it is created. That must come BEFORE any foreign key or `NOT NULL`-defaulted column added later in this migration validates existing rows against it (see "Data-validating constraint ordering" below).
6. Standalone constraints (`ALTER TABLE … ADD CONSTRAINT` — UQ, CK, DF)
7. Non-unique indexes (`CREATE NONCLUSTERED INDEX`)
8. Foreign keys
9. Synonyms (with `$()` variables already substituted)
10. Child/fact-data inserts and data backfills (idempotent guards)

**Why this order**:
- Tables must exist before constraints can reference their columns.
- A lookup or parent table must be *populated* before a FK forces existing rows to reference it. The same goes for a `NOT NULL` column with a `DEFAULT`. Otherwise the constraint check fails with **error 547** on any environment that already holds data.
- FKs come after all referenced tables exist and are seeded.
- Synonyms are independent.
- Child and fact data depend on the final shape of the table.

**Data-validating constraint ordering (error 547 guard)**: some changes to an ALTERed table that already has rows make SQL Server validate every existing row against the referenced table. Adding a `FOREIGN KEY` does, and so does adding a `NOT NULL` column with a `DEFAULT`. If that referenced (lookup) table is created in the *same* migration, its reference rows must be inserted before the constraint or column is added. That means at minimum every value used as a column `DEFAULT`. This is why reference data belongs in the VERSION migration, never in a Post-Deployment script that runs after Flyway migrate: the seed and the constraint live in one script, seed first. The signature of this defect is a migration that passes on an empty environment (e.g. staging) but fails with 547 on a populated one (e.g. production).

**Backfill-before-drop ordering**: if any `INSERT … SELECT` / `UPDATE … FROM` reads from a table this migration also DROPs (a cutover backfill), emit the backfill FIRST and DROP the source table LAST. Never drop a table before the data migration that reads it: the drop strands the data, and an `IF OBJECT_ID(...) IS NOT NULL`-guarded backfill silently does nothing. You may drop the source table's dependent FKs and indexes early if a later step needs that, such as restructuring a table it referenced. Keep the source table itself until the backfill has run.

For DROPs in deletion scenarios, reverse the order: triggers → FKs → indexes → constraints → table → UDT. The exception is a table that feeds a cutover backfill in the same migration: drop it only after that backfill runs.

## Reference-Data Files

A changed `.sql` file outside the schema object folders holds data, not schema. Examples are `Scripts/ReferenceData/*.sql` (Kind `other`), typically a `None` item in the `.sqlproj`. Its rows go into the VERSION migration at the seed position above. Rewrite them as per-row idempotent inserts (`INSERT … SELECT … FROM (VALUES …) AS src WHERE NOT EXISTS (…)`), keeping the values exactly as given. Never put a whole multi-row `INSERT` behind a single `IF NOT EXISTS`.

## Index Creation Standards

All indexes on **existing tables** in VERSION migrations MUST include FILLFACTOR and ONLINE options. **CRITICAL**: The syntax differs between `CREATE INDEX` and `ALTER TABLE ADD CONSTRAINT`:

**For `CREATE INDEX` / `ALTER INDEX REBUILD`:**
- **Primary Keys & Clustered Indexes**: `FILLFACTOR = 90`
- **Non-Clustered Indexes & Unique Constraints**: `FILLFACTOR = 95`
- **ONLINE**: `ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF))`
- **RESUMABLE**: **DO NOT USE**. Flyway wraps each version migration in a transaction, and `RESUMABLE = ON` inside one fails with SQL Server error 574: `RESUMABLE INDEX statement cannot be used inside a user transaction`

**For `ALTER TABLE ADD CONSTRAINT` (PK or UQ):**
- **FILLFACTOR**: Same as above (90 for clustered, 95 for non-clustered)
- **ONLINE**: `ONLINE = ON` (flat, with **NO** `WAIT_AT_LOW_PRIORITY`; SQL Server rejects it with error 155)
- **RESUMABLE**: **NOT supported** — do not include
- **Identity/Sequence PKs**: Add `OPTIMIZE_FOR_SEQUENTIAL_KEY = ON`

Exception: Inline PRIMARY KEY inside `CREATE TABLE` does NOT require FILLFACTOR or ONLINE. However, `OPTIMIZE_FOR_SEQUENTIAL_KEY = ON` DOES apply inline when the PK column is IDENTITY.

**ONLINE after an ALTER of the same table**: the same transaction keeps any earlier `ALTER TABLE` on that table holding its schema lock. A following `ONLINE = ON` index build then blocks the table anyway (SQL Server message 1970), and `sqlmig check` warns about it. On a large or busy table, ship the index in a migration of its own.

See `references/index-standards.md` for detailed patterns.

## CI/CD Security Constraints

The deploy role named in the Repository Configuration has least-privilege permissions. Generated migrations:
- **CAN**: CREATE/ALTER/DROP individual objects, CREATE SCHEMA, DML operations (SELECT/INSERT/UPDATE/DELETE)
- **CANNOT**: DROP SCHEMA, GRANT/REVOKE to other users/roles, ALTER AUTHORIZATION, TRUNCATE TABLE
- **VERSION migration GRANTs**: ONLY `GRANT ... ON SCHEMA::` to the deploy role for new schemas
- **REPEATABLE migration GRANTs**: copied verbatim from the source files by the build step
- **NEVER** generate GRANT statements for roles/users other than the deploy role in VERSION migrations

See `references/security-constraints.md` for the full permission model.

## SQL Coding Standards

Follow project SQL standards in all generated migration scripts:
- **Data types**: Always specify length/precision — `VARCHAR(50)`, `DECIMAL(12,6)`, `DATETIME2(2)` (see `references/sql-standards.md`)
- **Naming**: PascalCase columns, constraint prefixes (PK_, FK_, UQ_, CK_, DF_, IX_)
- **Formatting**: Tabs for indentation, no unnecessary brackets, no trailing spaces
- **Error handling**: Use THROW (not RAISERROR). Use the project's own error numbers, which must be 50000 or above.
- **No MERGE**: Use UPDATE + `IF @@ROWCOUNT = 0` INSERT pattern instead
- **SET NOCOUNT ON**: All stored procedures must include `SET NOCOUNT ON` as the first statement after `BEGIN`
- **SCOPE_IDENTITY**: Use `SCOPE_IDENTITY()` instead of `@@IDENTITY` — never generate `@@IDENTITY` in migration scripts
- **STRING_AGG**: Prefer `STRING_AGG()` over `FOR XML PATH` for string concatenation in stored procedures (SQL Server 2017+)
- **No deprecated types**: Never use `TEXT`, `NTEXT`, or `IMAGE` — use `VARCHAR(MAX)`, `NVARCHAR(MAX)`, `VARBINARY(MAX)`
- **Headers**: Preserve source file headers verbatim. Never add or change an `Author` line, and never put a tool's name in one.

See `references/sql-standards.md` for complete standards and examples.

## Comments

Preserve all original comments verbatim. Only add: `-- Migration generated for branch: {{BRANCH_NAME}}`

## Permissions-Only Files

Some Table or Synonym files contain **only** `GRANT`, `REVOKE`, or `DENY` statements, with no `CREATE`, `ALTER`, or `DROP TABLE/SYNONYM` (Kind `permissions`). They go into the **REPEATABLE** migration, not VERSION. Treat them identically to Views/SPs/Functions.

## Renamed Files (Status R)

Git rename status (`R###`) means the file was moved or renamed. Treat it as a **new file**, using the current (destination) content. Do NOT generate a DROP for the old path: the database object name may not have changed.

## Security Folder Files

Files under `Security/` directories:
- **Role/User/Schema definition files** (CREATE ROLE, CREATE USER, ALTER ROLE ADD MEMBER, CREATE SCHEMA) → **VERSION** migration
- **Permission-only files** (only GRANT/REVOKE/DENY) → **REPEATABLE** migration
- **The deploy role's own file** → neither (see Permission Placement Rules)

## Whitespace-Only Diffs

Skip a modified file entirely if its diff contains **only whitespace changes**: blank lines added or removed, trailing-space changes, or indentation-only changes. Generate no migration content for it. In Claude Code these entries carry `WhitespaceOnly: true`.

## Embedded Triggers in Table Files

When a table source file contains both a `CREATE TABLE` and one or more `CREATE TRIGGER` statements:
- **Table structure** (CREATE TABLE, constraints, indexes) → **VERSION** migration
- **Trigger definitions** → **REPEATABLE** migration (using `CREATE OR ALTER TRIGGER`)

Split the content accordingly. Never put trigger definitions in VERSION migrations.

## Self-Validation Checklist

Before emitting your response, verify each migration script passes ALL of these checks:

1. **BEGIN/END matching** — every `BEGIN` has a corresponding `END`
2. **GO separators** — `GO` appears between DDL batches; never inside a `BEGIN...END` block
3. **Data types valid** — no bare `VARCHAR()`, `NVARCHAR()`, or `DECIMAL` without length/precision
4. **Filename format** — VERSION: `V{major}.{minor}__{date}.{database}.{branch}.sql`; REPEATABLE: `R__{date}.{database}.{branch}.sql`
5. **Permission placement** — object-level GRANTs only in REPEATABLE; schema-level GRANTs only in VERSION
6. **No duplicate objects** — each CREATE/ALTER appears only once per migration
7. **Idempotent guards** — all VERSION objects wrapped in `IF EXISTS`/`IF NOT EXISTS`
8. **CREATE OR ALTER** — all REPEATABLE objects use `CREATE OR ALTER`, never plain `CREATE`
9. **No SQLCMD variable syntax** — no `$(...)` patterns remain in output; every variable is replaced with its database name from the Repository Configuration
10. **Reference data inserts** — a multi-row INSERT must NOT be wrapped in a single `IF NOT EXISTS` block, because every row after the first is skipped. Use per-row `IF NOT EXISTS` or the `INSERT...SELECT...EXCEPT` pattern instead
11. **Index options**:
    - `CREATE INDEX` on an existing table includes FILLFACTOR (90 clustered, 95 non-clustered) and `ONLINE = ON (WAIT_AT_LOW_PRIORITY ...)`, with **NO** `RESUMABLE` (error 574: it cannot run inside the migration's transaction).
    - `ALTER TABLE ADD CONSTRAINT PRIMARY KEY/UNIQUE` includes FILLFACTOR and `ONLINE = ON`, flat: **NO** `WAIT_AT_LOW_PRIORITY` and **NO** `RESUMABLE`.
    - IDENTITY/SEQUENCE PKs include `OPTIMIZE_FOR_SEQUENTIAL_KEY = ON`.
12. **Security constraints** — no `GRANT` to users/roles other than the deploy role in VERSION migrations; no `DROP SCHEMA`, `ALTER AUTHORIZATION`, or `TRUNCATE TABLE`
13. **Deprecated data types** — no `TEXT`, `NTEXT`, or `IMAGE` types in any generated script; use `VARCHAR(MAX)`, `NVARCHAR(MAX)`, `VARBINARY(MAX)` instead
14. **SCOPE_IDENTITY check** — no `@@IDENTITY` in any generated code; use `SCOPE_IDENTITY()` instead
15. **SELECT * check** — no `SELECT *` in generated stored procedure queries (exception: `EXISTS (SELECT * ...)` is allowed)
16. **Deprecated join syntax** — no `*=` or `=*` (old-style outer join) operators; use `LEFT OUTER JOIN` / `RIGHT OUTER JOIN` instead
17. **SET NOCOUNT ON** — all stored procedures in REPEATABLE migrations have `SET NOCOUNT ON` as the first statement after `BEGIN`
18. **TRY-CATCH** — all stored procedures with `BEGIN TRANSACTION` also have `BEGIN TRY`/`BEGIN CATCH` with `ROLLBACK` and `THROW`
19. **Dynamic SQL safety** — no `EXEC(@variable)` or string concatenation (`''' + @param + '''`) in generated code; use `sp_executesql` with parameters
20. **No cursors** — no `DECLARE ... CURSOR` in generated stored procedures; use set-based operations instead
21. **SARGable predicates** — no `YEAR()`, `MONTH()`, `CONVERT()`, `CAST()`, `LEFT()`, `SUBSTRING()`, `UPPER()`, `LOWER()` applied to columns in WHERE clauses; rewrite using range comparisons or LIKE patterns (see `references/sql-standards.md`)
22. **No sp_ prefix** — stored procedure names must not start with `sp_` (reserved for SQL Server system procedures)
23. **No leading wildcard LIKE** — avoid `LIKE '%value'` patterns that prevent index usage; use full-text search or redesign the query
24. **VARCHAR(1)/VARCHAR(2) check** — use `CHAR(1)` or `CHAR(2)` instead of `VARCHAR(1)` or `VARCHAR(2)` for fixed-length single/dual-character columns (avoids 2-byte overhead per row; SSDT rule SR0009)
25. **No MERGE statements** — never generate MERGE; use UPDATE + `IF @@ROWCOUNT = 0` INSERT pattern instead (MERGE has known concurrency bugs in SQL Server)
26. **OPTIMIZE_FOR_SEQUENTIAL_KEY** — all `CREATE TABLE` with IDENTITY PK must include `WITH (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON)` on the PRIMARY KEY constraint
27. **Covering indexes** — when generating indexes for known query patterns, place WHERE/JOIN/ORDER BY columns as key columns and SELECT-only columns in INCLUDE
28. **SET XACT_ABORT ON** — all stored procedures with `BEGIN TRANSACTION` must include `SET XACT_ABORT ON` (guarantees rollback on query timeouts and linked server errors)
29. **Schema qualification** — all table, view, function, and procedure references must be schema-qualified (`sales.TableName`, not bare `TableName`)
30. **Explicit INSERT columns** — all `INSERT INTO` statements must list column names explicitly; never `INSERT INTO Table VALUES (...)`
31. **EXISTS vs COUNT** — use `IF EXISTS (SELECT 1 ...)` for existence checks, never `IF (SELECT COUNT(*) ...) > 0`
32. **Literal column DDL** — every `DROP COLUMN` / `ADD` / `ALTER COLUMN` names its column literally in its own guarded block. Whatever the column count, never derive which columns to change with a cursor, a `WHILE` loop, a `sys.columns` anti-join, a comma-separated column list, or `sp_executesql` over concatenated DDL.
33. **Seed before validate** — every lookup table this migration creates and seeds is seeded before any foreign key or `NOT NULL` + `DEFAULT` column validates existing rows against it

If any check fails, fix it before responding.

## Forbidden

NEVER generate Post-Deployment scripts, ScriptsIgnoredOnImport, Script.Post, or any files under a Scripts\Post-Deployment path. All data seeding, reference data inserts, and one-time data operations MUST go into VERSION migration scripts with idempotent IF NOT EXISTS patterns.

## Output Format

In a one-shot prompt (CI, or `sqlmig prompt`), return your response in this XML structure:

```xml
<MIGRATION_RESPONSE>
<REPEATABLE_MIGRATION>
<FILENAME>R__{{DATE}}.{{DATABASE}}.{{BRANCH_NAME}}.sql</FILENAME>
<CONTENT>SQL content here</CONTENT>
</REPEATABLE_MIGRATION>
<VERSION_MIGRATION>
<FILENAME>{{NEXT_VERSION}}__{{DATE}}.{{DATABASE}}.{{BRANCH_NAME}}.sql</FILENAME>
<CONTENT>SQL content here</CONTENT>
</VERSION_MIGRATION>
<SUMMARY>Brief description of changes</SUMMARY>
</MIGRATION_RESPONSE>
```

Omit `<REPEATABLE_MIGRATION>` or `<VERSION_MIGRATION>` sections if not needed. The repeatable section is optional: the build step rebuilds it from source either way.
Copy SQL exactly from source files, preserve format/comments, ensure correct syntax/order.

## Current Context

- **Branch**: {{BRANCH_NAME}}
- **Database**: {{DATABASE}}
- **Date**: {{DATE}}

## Changed Files

{{CHANGED_FILES_JSON}}
