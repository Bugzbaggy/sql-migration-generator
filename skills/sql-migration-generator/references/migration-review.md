# Migration Review Prompt (T-SQL syntax + object existence + security)

In Claude Code, step 6 of the skill applies this review to the two files it just built,
using the project's source tree as the catalogue. A CI step can send it as a one-shot prompt
(for example the **Claude migration review** step of a `generate-migration-scripts.yml`
workflow), appending these, after this prompt:

- `DATABASE` — the database name (e.g. Sales).
- `KNOWN_ROLES_SOURCE` — the raw text of the CI/CD role file(s) so you can
  determine which `role_*` names legitimately exist in this project.
- `KNOWN_SCHEMAS` — every schema that exists in this database.
- `KNOWN_OBJECTS` — the authoritative catalogue of every schema-qualified
  object (table, view, procedure, function, trigger, synonym, user-defined
  type) that is defined in the repository source tree, one `schema.Object` per
  line. An object is in this list if and only if it exists (or will exist after
  this branch deploys, because its source file is part of the branch). Match
  names **case-insensitively**. In Claude Code, build this list yourself from
  the `CREATE` statements under the configured `sourceRoot`.
- One or more `<FILE name="...">...</FILE>` blocks — the **final, on-disk**
  Flyway migration scripts that are about to be committed (versioned `V*.sql`
  and/or repeatable `R__*.sql`).

You are a deterministic reviewer. Do not guess. If something is ambiguous,
prefer the lower-severity classification and explain it in the relevant text.

---

## Part 1 — T-SQL syntax / compile validation

Act as the Microsoft SQL Server 2019/2022 (160) parser. Flyway runs each script
by splitting it on lines that contain only `GO` and executing **each batch
independently** through `SqlCommand.ExecuteNonQuery` — there is no SSMS, no
implicit batch wrapping, and no client-side statement splitting. Evaluate every
GO-separated batch on its own, because batch scope is what determines validity.

Report a syntax **error** only for things SQL Server would actually reject at
parse/compile time — the "Incorrect syntax near …" class. Examples (not
exhaustive):

- A common table expression whose `WITH` is **not** preceded by a
  semicolon-terminated statement in the same batch (error 319 — "the previous
  statement must be terminated with a semicolon"). This is the canonical case:
  an `IF … BEGIN … END` block followed directly by `WITH cte AS (…)` with no
  `;` after the `END`.
- Statements that require a terminating semicolon but lack one (`THROW`,
  `MERGE`, a statement immediately before a CTE).
- Unbalanced `BEGIN`/`END`, `BEGIN TRY`/`END TRY`/`BEGIN CATCH`/`END CATCH`, or
  unbalanced parentheses.
- Missing or stray commas in column lists, parameter lists, or `VALUES`.
- `GO` placed inside a statement/expression, or a batch that is otherwise
  syntactically incomplete.
- Misspelled/misplaced keywords, duplicated clauses, malformed `CREATE OR ALTER`.

Do **not** report (these are out of scope for Part 1):

- Style or anti-pattern lint (NOLOCK, `SELECT *`, naming, `sp_` prefix,
  data-type preferences) — that belongs to a separate SQL linter (for example nitsql).
- A missing referenced object — this is **not** out of scope; it is handled
  deterministically in **Part 3** against the object catalogue, not here.
- Anything else that parses successfully but might fail only at runtime (a
  permission or a performance concern).

Also emit non-blocking **warnings** (these never fail the build) for genuinely
useful correctness smells that still parse:

- A repeatable migration (`R__*.sql`) that contains `CREATE PROCEDURE/FUNCTION/
  VIEW/TRIGGER` **without** `CREATE OR ALTER` (repeatable migrations must be
  idempotent).
- `CREATE TABLE` without a `PRIMARY KEY`.
- A trigger defined before the table it targets, within the same migration.
- A multi-row `INSERT` wrapped in a single `IF NOT EXISTS` guard (rows after the
  first may be silently skipped).

`syntax.status` MUST be `"FAIL"` if and only if `syntax.errors` is non-empty.

## Part 2 — Security / permissions audit

Identify every `GRANT` / `REVOKE` / `DENY` statement in the migration files and
classify each one. Use `KNOWN_ROLES_SOURCE` to decide whether a referenced
`role_*` principal actually exists in this project.

- An **issue** (recorded in `security.issues`) for any dangerous permission —
  `CONTROL`, `ALTER ANY`, or `CONTROL SERVER` — granted to any principal
  (privilege-escalation risk).
- A **warning** for:
  - An **object-level** permission (`ON OBJECT::`) found in a **versioned**
    (`V*.sql`) migration — object grants belong in the repeatable migration.
  - A **schema-level** permission (`ON SCHEMA::`) found in a **repeatable**
    (`R__*.sql`) migration — schema grants belong in the versioned migration.
  - A `role_*` principal that is not present in `KNOWN_ROLES_SOURCE`.

`security.passed` is `true` when `security.issues` is empty (warnings do not
affect `passed`).

## Part 3 — Referenced-object existence validation

This is the check that catches a migration referencing an object that does not
exist anywhere — a typo (`sales.ProductList_STG` instead of `sales.ProductList`) or an
object that was never added to source control. SQL Server compiles such a
reference (deferred name resolution) but it **fails at deploy/runtime**, so it
must be caught here before the migration is committed.

For every schema-qualified object the migration **reads from or writes to** —
i.e. a `schema.Object` appearing after `FROM`, `JOIN`, `INSERT INTO`,
`UPDATE`, `DELETE FROM`, `MERGE INTO`, `USING`, `EXEC`/`EXECUTE`, `APPLY`, or as
a user-defined type in `DECLARE @x AS schema.Type` / a parameter declaration —
decide whether it resolves.

An object reference is **resolved** (do not flag) if ANY of these hold:
  1. It appears in `KNOWN_OBJECTS` (case-insensitive), OR
  2. It is created earlier in the same migration set — a `CREATE` /
     `CREATE OR ALTER` of that exact object precedes the reference, OR
  3. Its schema is **not** in `KNOWN_SCHEMAS` — it targets a schema this
     database does not own (a multi-part cross-database / linked-server name, or
     an external schema outside our source control). We cannot validate these,
     so record them in `objects.warnings`, never in `objects.missing`.

Do **not** treat the following as object references (they are local, transient,
or system, and are always valid):
  - Temp tables (`#name`, `##name`) and table variables (`@name`).
  - Common table expression names (`WITH cte AS (…)`) and their later use.
  - Table / column aliases.
  - Unqualified names (no `schema.` prefix) — out of scope; skip them.
  - System objects (`sys.*`, `INFORMATION_SCHEMA.*`) and built-in functions.
  - The **target** of a `CREATE SYNONYM … FOR <target>` — synonym targets are
    late-bound; SQL Server never resolves them at create/deploy time, so a
    cross-database / multi-part target (e.g. `AppCatalog.geo.Country`) is always
    valid here. Skip it entirely — record it in neither `objects.missing` nor
    `objects.warnings`.
  - The **linked-server name** in any `EXEC (…) AT [server]` statement (e.g.
    `EXEC (@sql) AT [REMOTE_DW]`), and the server part of a four-part name. A
    linked server is an instance-level object provisioned outside source control
    and resolved by SQL Server at runtime, never at deploy; it is not a database
    object and can never appear in `KNOWN_OBJECTS`. Every linked-server name is
    allowlisted by virtue of being a linked server (e.g. `REMOTE_DW`,
    `REPORTING_LS`, `REGION2_LS`). Skip it entirely — record it in neither
    `objects.missing` nor `objects.warnings`.

A **missing** object (recorded in `objects.missing`) is a reference whose schema
**is** in `KNOWN_SCHEMAS` but the object is **neither** in `KNOWN_OBJECTS`
**nor** created earlier in the migration set. This is BLOCKING. For each one,
suggest the closest real name from `KNOWN_OBJECTS` in the same schema if there is
an obvious near-match (it usually indicates a typo).

`objects.status` MUST be `"FAIL"` if and only if `objects.missing` is non-empty.

---

## Output contract

Return ONLY a single JSON object wrapped EXACTLY between `<REVIEW>` and
`</REVIEW>` tags. No prose before or after, no markdown code fences.

<REVIEW>
{
  "syntax": {
    "status": "PASS",
    "errors": [
      {
        "file": "R__2026-06-01.Sales.branch.sql",
        "batch": 4,
        "line": 57,
        "message": "Incorrect syntax near the keyword 'with'. The previous statement must be terminated with a semicolon.",
        "offendingSql": "END\n\nWITH XCResolved AS (",
        "fix": "Terminate the preceding END with a semicolon: END; (or use ;WITH)."
      }
    ],
    "warnings": [
      { "file": "R__2026-06-01.Sales.branch.sql", "message": "Procedure created without CREATE OR ALTER." }
    ]
  },
  "objects": {
    "status": "FAIL",
    "missing": [
      {
        "file": "R__2026-06-11.Sales.feature.product-report.sql",
        "object": "sales.ProductList_STG",
        "referencedAt": "INNER JOIN in sales.vwProductSales",
        "message": "Object sales.ProductList_STG does not exist in KNOWN_OBJECTS and is not created in this migration. Likely a typo for sales.ProductList."
      }
    ],
    "warnings": []
  },
  "security": {
    "passed": true,
    "statements": [
      { "type": "GRANT", "permission": "EXECUTE", "scope": "OBJECT", "target": "sales.Customer_Get", "role": "role_reporting", "migration": "repeatable" }
    ],
    "issues": [],
    "warnings": []
  }
}
</REVIEW>

When everything is clean, return `"status": "PASS"` for both `syntax` and
`objects` with empty `errors`/`missing`, `"passed": true` for `security`, and
empty `issues`. Always include every array key even when empty.