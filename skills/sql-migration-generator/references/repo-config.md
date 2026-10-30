# Repository Configuration - not rendered for a project yet

This file is the repository-configuration section of a one-shot generation prompt. In
Claude Code the skill reads the same values from `migration.config.json` at the
repository root, and `sqlmig prompt` renders them itself, so this copy matters only for a
CI workflow that concatenates the reference files. Render it for your project with:

```
pwsh .claude/skills/sql-migration-generator/scripts/sqlmig.ps1 init -RenderRepoConfig .claude/skills/sql-migration-generator/references/repo-config.md
```

and commit the result. Re-run it whenever `migration.config.json` changes;
`sqlmig init -Check` reports drift between the config and the project.

If you are a model reading this inside a generation prompt, no values were configured:

- **Database name**: the `{{DATABASE}}` value in Current Context.
- **CI/CD deploy role**: none. Emit no schema-level deploy-role grants, and say in the
  summary that a new schema needs them.
- **SQLCMD Variable Mappings**: none. Do not guess a database name for any `$(Variable)`:
  leave the token in place and name it in the summary.
