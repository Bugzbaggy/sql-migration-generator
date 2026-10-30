# Impact Analysis Prompt (schema risk + object dependencies)

This prompt is for a CI step that rates a branch's risk before generation (for example the
**Analyze PR impact** step of a `generate-migration-scripts.yml` workflow; Claude Code does
not use it). The step performs the deterministic search (git diff + repo-wide `git grep`)
and hands you the raw results; **your** job is the judgment that a regex does badly.

The step appends, after this prompt:

- `DATABASE` — the database name (e.g. Sales).
- `KNOWN_SCHEMAS` — the schema directory names that exist under the database
  folder (the legitimate schema list).
- `HIGH_RISK_KEYWORDS` — substrings that mark a schema as business-critical
  (e.g. billing, routing, financial, pricing).
- `CHANGED_FILES` — each changed `*.sql` source file with its git status
  (`A` added, `M` modified, `D` deleted, `R###` renamed) and path.
- `STRUCTURE_DIFFS` — unified diffs for added/modified/deleted **Tables** and
  **Synonyms** files (so you can see exactly which columns/objects changed).
- `GREP_HITS` — for each table/synonym/column that was **dropped or modified**,
  the raw repo-wide search hits in `path:line:content` form. These are
  *candidate* references only.

## What to judge

1. **Real references vs. noise.** A `GREP_HITS` line is a real dependency only
   if the match is *code that uses the object*. Exclude:
   - comment lines (the match sits inside a `--` or `/* */` comment),
   - the object's own definition (`CREATE [OR ALTER] PROCEDURE/FUNCTION/VIEW/
     TRIGGER/TABLE …` for the object itself),
   - matches inside the `Migration/` or `Security/` folders,
   - the changed file itself.
   Report real references as repo-relative paths (strip the leading
   `DATABASE/`), de-duplicated.

2. **Dropped columns.** From `STRUCTURE_DIFFS`, identify columns removed from a
   modified table (a removed line that declares a real column — ignore
   constraint/key/`GO`/`BEGIN`/`END` noise). Treat each dropped column as a
   potential dependency target and use its `GREP_HITS` to list references.

3. **Per-schema risk.** For each changed schema assign `risk`:
   - `HIGH` — a structure change (Tables/Synonyms/User Defined Types) on a
     schema whose name matches a `HIGH_RISK_KEYWORDS` entry, OR a dropped
     object/column referenced by **3 or more** real dependencies, OR a
     synonym-heavy schema (>10 synonyms) undergoing structure change.
   - `MEDIUM` — a structure change, OR a high-risk-keyword match, OR a
     dropped object/column with 1–2 real dependencies.
   - `LOW` — everything else (e.g. a repeatable-only change).
   `changeType` is `"structure"` if the schema has any Tables/Synonyms/UDT
   change, else `"repeatable"`.

4. **Overall risk** is the maximum across schemas (`HIGH` > `MEDIUM` > `LOW`;
   `NONE` only when no schemas changed).

## Output contract

Return ONLY a single JSON object wrapped EXACTLY between `<IMPACT>` and
`</IMPACT>` tags. No prose, no markdown fences.

<IMPACT>
{
  "schemas": [
    { "name": "ref", "risk": "MEDIUM", "changeType": "structure", "reason": "DELETED object with 2 dependencies" }
  ],
  "overallRisk": "MEDIUM",
  "dependencies": [
    {
      "droppedObject": "ref.Region",
      "changeType": "DELETED",
      "referencedBy": ["sales/Stored Procedures/Customer_GetByRegion.sql", "sales/Views/vwRegionSales.sql"],
      "refCount": 2
    }
  ],
  "crossDatabaseImpact": [],
  "summary": "1 schema(s) affected, overall risk: MEDIUM"
}
</IMPACT>

`changeType` inside `dependencies[]` is `"DELETED"` for a dropped object or
`"COLUMN_DROPPED"` for a dropped column (use `table.column` as `droppedObject`).
Always include every key; use empty arrays when there is nothing to report.
When no schemas changed, return `schemas: []`, `overallRisk: "NONE"`,
`dependencies: []`, and a `summary` of `"No schemas affected"`.
