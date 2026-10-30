# Contributing to sql-migration-generator

A Claude Code skill that generates Flyway migration scripts for SQL Server from an SSDT
branch, with the deterministic half (context, repeatable-script build, order check) in
PowerShell.

Contributions are welcome. This project is maintained in spare time, so please
open an issue before starting anything large.

## Ground rules

1. **No real infrastructure in commits.** Hostnames, IPs, database names,
   service accounts, and credentials must be placeholders. See
   [SECURITY.md](SECURITY.md).
2. **One logical change per pull request.** Small PRs get reviewed; large
   ones stall.
3. **Explain the failure mode.** For a bug fix, say what broke and how to
   reproduce it. "Fixes a bug" is not reviewable.
4. **Prove it against SQL Server.** A change to a generation rule or to what `build`
   emits must keep `tests/e2e/Invoke-E2E.ps1` passing: parsing is not deploying.

## Getting started

```bash
git clone https://github.com/Bugzbaggy/sql-migration-generator.git
cd sql-migration-generator
pwsh -c "Invoke-Pester ./tests"
```

A change to the sample branch (`examples/`) or to `build` changes
`examples/expected/`. Regenerate it by running the flow on a sample repository (see
`tests/SampleRepo.ps1`). Review the diff line by line, then commit it with the change that
caused it.

## Pull request checklist

- [ ] CI is green (PSScriptAnalyzer, Pester on Linux and Windows, end-to-end, leak scan)
- [ ] No secrets, internal hostnames, or customer data introduced
- [ ] New behaviour has a test, or the PR says why it cannot
- [ ] Docs updated if behaviour changed

## Reporting bugs

Open an issue with the version, the platform, what you expected, what
happened, and the smallest reproduction you can manage. The context file
(`.git/sqlmig/context.json`) and the two generated scripts are usually enough. Strip
anything real from them first.
