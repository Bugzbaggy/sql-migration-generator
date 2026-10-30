# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's
[private vulnerability reporting](https://github.com/Bugzbaggy/sql-migration-generator/security/advisories/new)
instead.

## What the tool can touch

- `sqlmig.ps1` reads your repository and writes only:
  - the branch's two scripts under the migration folder;
  - its context file in the git directory;
  - with `project -Apply`, the deploy-role file and the `.sqlproj`.
- It never connects to a database, and never runs `git commit` or `git push`.
- `context -RemoveExisting` deletes only this branch's previously generated scripts. It
  keeps any that has uncommitted edits unless you pass `-Force`.
- The generated scripts run with your deploy role's permissions. The rules keep grants to
  that role, and to schema-level grants for new schemas, in the versioned script. They never
  emit `DROP SCHEMA`, `ALTER AUTHORIZATION` or `TRUNCATE TABLE`. Review the scripts like any
  other code before they reach production.

## Scope note for contributors

Treat every example database, role, connection string, hostname and account name as a
placeholder. Never paste real ones into issues, pull requests or test fixtures, and that
includes logs and context files attached to bug reports.

Values such as `Sales`, `AppCatalog`, `role_app_ci`, `role_reporting` and `Example Author`
are deliberately fictional. Keep them that way.
