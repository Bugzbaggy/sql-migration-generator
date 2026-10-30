# sql-migration-generator

A [Claude Code](https://claude.com/claude-code) skill that turns the changes on an SSDT
database branch into the two [Flyway](https://documentation.red-gate.com/fd) migration
scripts SQL Server needs. The versioned `V__` script covers tables, indexes, keys,
synonyms, types and reference data. The repeatable `R__` script covers views, procedures,
functions and triggers. It then checks that both will deploy in the order they are written.

[![CI](https://github.com/Bugzbaggy/sql-migration-generator/actions/workflows/ci.yml/badge.svg)](https://github.com/Bugzbaggy/sql-migration-generator/actions/workflows/ci.yml)
[![Claude Code skill](https://img.shields.io/badge/Claude%20Code-skill-8A63D2)](https://claude.com/claude-code)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Why it exists

SSDT keeps the *desired state* of every object in source control. Flyway deploys
*changes*. Getting from one to the other by hand is where migrations break:

- a `CREATE TABLE` re-run against a table that exists;
- a foreign key added before its lookup table is seeded. It passes on an empty staging
  database and fails with error 547 on production;
- a procedure created before the view it reads;
- a `$(Catalog)` token that SSDT resolves at publish time and Flyway never does.

This tool splits the work. **Claude writes only the versioned script**, from the diff,
following 33 explicit rules. **A deterministic PowerShell script does everything else**:

- finds the changes and numbers the version;
- builds the repeatable script from the source files, in dependency order;
- moves misplaced grants and maps SQLCMD variables;
- checks the object order of both scripts.

It never guesses what can be computed.

## Install

You need Claude Code, [PowerShell 7.2+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
(`pwsh`) and git. Flyway is needed only to deploy.

**For every repository you work in** (a user-level skill):

```bash
git clone https://github.com/Bugzbaggy/sql-migration-generator.git
mkdir -p ~/.claude/skills
cp -r sql-migration-generator/skills/sql-migration-generator ~/.claude/skills/
```

On Windows, the target is `%USERPROFILE%\.claude\skills\`:

```powershell
Copy-Item -Recurse sql-migration-generator\skills\sql-migration-generator "$env:USERPROFILE\.claude\skills\"
```

**For one repository** (shared with your team through git): copy the same folder into that
repository's `.claude/skills/` instead. Pull this repository and copy again to upgrade.

## Use

On your feature branch, in Claude Code:

```
/sql-migration-generator
```

or just ask: *"generate the migration scripts for this branch"*. The first time, it runs
`sqlmig init`, shows you the `migration.config.json` it derived from your `.sqlproj`, and
asks you to confirm it. After that, a run works like this:

1. **context** finds what changed since the merge base with your base branch, including
   uncommitted edits. It deletes this branch's previously generated scripts and names the
   next version.
2. Claude **writes the versioned script** from the diffs.
3. **build** builds the repeatable script and cleans up the versioned one.
4. **check** verifies the order. On failure, Claude fixes the versioned script and repeats,
   up to three rounds.
5. Claude **reviews** both files for syntax, missing objects and grants, and reports.

Nothing is committed unless you ask.

The same commands run without Claude. Run them from anywhere in the database repository:

```powershell
$sqlmig = "$HOME/.claude/skills/sql-migration-generator/scripts/sqlmig.ps1"
pwsh $sqlmig context -RemoveExisting   # what changed, where the scripts go
# ...write the V__ script (or: pwsh $sqlmig prompt, send it to any model, then
#    pwsh $sqlmig apply -ResponseFile reply.txt)
pwsh $sqlmig build                     # finish V__, build R__
pwsh $sqlmig check                     # object order; exit 1 = would not deploy
pwsh $sqlmig project -Apply            # deploy-role grants + .sqlproj items
```

| Command | Does | Exit codes |
|---|---|---|
| `init` | Writes `migration.config.json` from the `.sqlproj`. `-Check` reports drift; `-RenderRepoConfig <file>` writes the configuration section a CI prompt needs | 0, 1 (`-Check` found an error) |
| `context` | Diffs the branch against the merge base and writes the context into the git directory (never committed). `-RemoveExisting` deletes this branch's old scripts, but keeps one with uncommitted edits unless `-Force`. `-CommittedOnly` ignores the working tree, as CI does. `-Base`, `-Branch` and `-Date` override the defaults | 0, 1 |
| `build` | Finishes `V__` and builds `R__` (below) | 0, 1 (unmapped SQLCMD variable) |
| `check` | Object-order check of this branch's two scripts | 0 pass, 1 problems, **3 could not run** (not a pass) |
| `project` | Adds the deploy-role grants for each new schema folder and the `.sqlproj` items for new files, and removes items for deleted ones. A dry run unless `-Apply`; skips SDK-style projects | 0, 1 |
| `prompt` | Writes the one-shot generation prompt, for any model | 0, 1 |
| `apply` | Writes the `V__` from a model's `<MIGRATION_RESPONSE>` (`-ResponseFile`); refuses a truncated one | 0, 1 |

## What `build` does, deterministically

- **Builds `R__` from the source files**, not from the model. It turns `CREATE` into
  `CREATE OR ALTER` and keeps object grants and file headers verbatim. It takes the
  triggers and object grants out of table files, and drops deleted views, procedures,
  functions and triggers.
- **Orders `R__` by actual references**: functions → views → procedures → triggers, with
  strongly connected components for procedures that call each other. Comments and string
  literals don't count as references; dynamic SQL does. A drop that a schema-bound object
  still depends on is moved after that object.
- **Drops a trigger that a table file no longer defines**, unless another file still
  creates it.
- **Re-creates whatever a `DROP TYPE` takes with it**, and drops it first in the `V__`.
- **Moves object-level grants** out of `V__`, and **routes schema-level grants** into it.
- **Maps every `$(Variable)`** to its database name, keeping brackets when a name needs
  them, and fails on any variable with no mapping.
- **Refuses to write an `R__` batch that cannot be re-run.** Only `CREATE OR ALTER`,
  `DROP ... IF EXISTS`, `GRANT`/`REVOKE`/`DENY` and `SET` are allowed.

## What `check` catches before a deploy does

In the versioned script it catches:
- an object used before it is created, or after it is dropped;
- an unguarded `CREATE` of something that already exists;
- a column used before the `ALTER TABLE … ADD` that adds it, or by DML in the same batch
  (Msg 207);
- a foreign key added before its lookup table is seeded (error 547 once the table has rows);
- a `DROP TYPE` or `DROP TABLE` that something still references;
- a dropped repeatable object that the `R__` never re-creates.

Across the two scripts it catches a `V__` that uses an object this branch only adds in
the `R__`, which Flyway runs later. In either script it catches a leftover `$(Variable)`.

It **warns** when an `ONLINE = ON` index follows an `ALTER TABLE` of the same table.
Flyway runs the script in one transaction, so the earlier schema lock makes the build
offline (SQL Server message 1970). The end-to-end test reproduces exactly that message.

## Configuration: `migration.config.json`

At the repository root. `init` writes it; edit it by hand after that.

| Key | Example | Meaning |
|---|---|---|
| `database` | `Sales` | Database name: in file names and in three-part names that mean "this database" |
| `project` | `Sales/Sales.sqlproj` | The SSDT project (`init`, `project`) |
| `sourceRoot` | `Sales` | Folder holding `<schema>/<Tables\|Views\|Stored Procedures\|Functions\|Triggers\|Synonyms\|User Defined Types>/` |
| `migrationDir` | `Migration` | Where the `V__`/`R__` scripts live |
| `baseBranch` | `main` | Compared against as `origin/<base>` if it exists, else the local branch |
| `firstVersion` | `V1.00001` | Version format and start; the minor's width (5) is kept, rolling over to the next major after 99999 |
| `ciRole` / `ciRoleFile` | `role_app_ci` | The least-privilege deploy role, which gets the seven schema grants for a new schema; its file never goes into a migration |
| `sqlcmdVariables` | `{ "Catalog": "AppCatalog" }` | `$(Variable)` → database name; a name may differ from its variable |
| `lineEndings` | `crlf` | Line endings of the written scripts (`crlf` or `lf`) |
| `excludeDirs` | `["Security", "Scripts", …]` | Folders under `sourceRoot` that are not schemas |

## The worked example

[`examples/`](examples/) is a complete, small SSDT repository:

| Path | What it is |
|---|---|
| `examples/sales-db/` | `main`: a `Sales` project with its first migration already deployed |
| `examples/sales-db.branch/` | A feature branch's changes, listed below; `deleted.txt` lists the deletions |
| `tests/fixtures/order-status.response.xml` | The model's reply, with two deliberate slips: an object grant in `V__`, and a raw `$(Catalog)` |
| `examples/expected/` | Exactly what the tool writes: the `V__`, the `R__`, and the `.sqlproj`/role-file diff |

The branch:
- adds a schema;
- adds a lookup table seeded from a reference-data script;
- adds a `NOT NULL` column with a default and a foreign key on a populated table;
- adds a covering index and a trigger in a table file;
- adds a function → view → procedure chain;
- deletes a procedure;
- adds a synonym that uses `$(Catalog)`.

`tests/e2e/Invoke-E2E.ps1` deploys the result with **Flyway 13.10.0 to SQL Server 2022**.
It deploys `main`, inserts rows, deploys the branch, re-runs both scripts to prove they
are idempotent, deploys everything again to an empty database, and asserts the final state:
- the seed rows;
- a trusted foreign key and the index fill factor;
- the dropped procedure;
- the synonym target and the grants;
- the new function, the trigger firing, and the new procedure's result.

## Using it in CI

The generation is a single prompt in, a single reply out. Any pipeline can run it:

```bash
pwsh sqlmig.ps1 context -CommittedOnly -RemoveExisting
pwsh sqlmig.ps1 prompt -OutFile prompt.md
# send prompt.md as one user message to your model; save the reply as reply.txt
pwsh sqlmig.ps1 apply -ResponseFile reply.txt
pwsh sqlmig.ps1 build
pwsh sqlmig.ps1 check   # fail the job on exit 1 or 3
```

Use a model with a large output limit and stream the response. A reply that stops at the
output cap has no `</MIGRATION_RESPONSE>`, and `apply` rejects it rather than writing half a
script.

[mssql-dacpac-cicd](https://github.com/Bugzbaggy/mssql-dacpac-cicd) has a complete GitHub
Actions workflow (`generate-migration-scripts.yml`) that reads this skill from
`.claude/skills/sql-migration-generator/`. Copy the skill folder there, then render the
repository section its prompt concatenates:

```bash
pwsh .claude/skills/sql-migration-generator/scripts/sqlmig.ps1 init -RenderRepoConfig \
  .claude/skills/sql-migration-generator/references/repo-config.md
```

`sqlmig init -Check` replaces a model-driven config-drift job: it fails on a `$(Variable)`
with no mapping and warns on a schema folder without deploy-role grants.

## Limits worth knowing

- **Versions are numbered from your working tree.** Two branches open at once can both take
  `V1.00007`. After you rebase on a base branch that gained one, run
  `context -RemoveExisting` again: your script moves to the next free number. The context
  warns about duplicates it can see.
- **It diffs source files, not databases.** A change made directly in production, outside
  source control, is invisible to it. Compare schemas separately if you suspect drift.
- **Reference data must be in a file.** Put rows in a script outside the schema folders,
  for example `Scripts/ReferenceData/<table>.sql`, as a `None` item. The skill turns them
  into per-row idempotent inserts in the `V__`.
- **Classic SSDT layout only**: `<schema>/<ObjectType>/<Name>.sql`. SDK-style projects
  work for generation; `project` leaves them alone.

## Tests

```powershell
Invoke-Pester ./tests              # Pester 5+: 35 tests on a throwaway git repository
pwsh ./tests/e2e/Invoke-E2E.ps1    # Docker: SQL Server 2022 + Flyway; a few minutes with the images pulled
```

CI runs both, plus PSScriptAnalyzer and the leak scan, on every push.

## License

[MIT](LICENSE)
