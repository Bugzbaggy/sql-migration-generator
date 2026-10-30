# CI/CD Security Constraints

The pipeline deploys with a least-privilege database role. This is the `ciRole` in the
Repository Configuration, written `<ciRole>` below (`role_app_ci` in the examples). Generated
migration scripts must respect these constraints.

## What Migrations CAN Do

| Operation | Permission Source |
|-----------|------------------|
| CREATE TABLE, VIEW, PROCEDURE, FUNCTION, TYPE, SYNONYM | Database-level CREATE permissions |
| ALTER existing objects (tables, procedures, views, etc.) | Schema-level ALTER |
| DROP individual objects (tables, views, indexes, constraints) | Schema-level ALTER |
| CREATE SCHEMA | Database-level CREATE SCHEMA |
| SELECT, INSERT, UPDATE, DELETE data | Schema-level DML permissions |
| EXECUTE stored procedures | Schema-level EXECUTE |
| CREATE FOREIGN KEY constraints | Schema-level REFERENCES |
| Read object metadata | VIEW DEFINITION |
| Access the Flyway history table (`dbo.flyway_schema_history`, plus any version-tracking table your pipeline keeps) | Table-level SELECT/INSERT/UPDATE/DELETE |

## What Migrations CANNOT Do

| Operation | Why Blocked |
|-----------|------------|
| DROP SCHEMA | CONTROL ON SCHEMA not granted |
| GRANT/REVOKE permissions to other users/roles | CONTROL ON SCHEMA not granted |
| ALTER AUTHORIZATION on schemas or objects | CONTROL ON SCHEMA not granted |
| TAKE OWNERSHIP of objects | CONTROL ON SCHEMA not granted |
| DROP DATABASE | ALTER ANY DATABASE explicitly denied |
| CREATE/ALTER logins or database users | No security principal management |
| BACKUP/RESTORE database | No backup operator rights |
| TRUNCATE TABLE | **Policy, not a permission**: it needs only ALTER on the table, which schema-level ALTER gives the role. Never generate it: it skips DELETE triggers, resets identities, and fails on a table that a foreign key references |

## Rules for Generated Migrations

1. **Schema-level GRANTs for the deploy role ONLY**: when creating a new schema, grant permissions ONLY to `<ciRole>`. Never generate GRANTs for other roles or users in VERSION migrations.

2. **Object-level GRANTs in REPEATABLE only**: grants such as `GRANT EXECUTE ON OBJECT::` go in REPEATABLE migrations, copied verbatim from the source file's GRANT statements. `sqlmig build` does the copying and moves any that reach a VERSION script.

3. **No DROP SCHEMA**: Never generate `DROP SCHEMA` statements. Drop individual objects instead.

4. **No permission management**: Never generate statements that GRANT or REVOKE permissions to/from users other than `<ciRole>` in VERSION migrations.

5. **No ownership changes**: Never generate `ALTER AUTHORIZATION` statements.

6. **The deploy role's own file stays out**: the role's definition and its grants are managed out of band. They refer to the role itself, so the deploy login cannot apply them. `sqlmig project -Apply` adds the seven schema grants (ALTER, SELECT, INSERT, UPDATE, DELETE, EXECUTE, REFERENCES) to that file for each new schema folder, so source control matches what the V__ grants.

## Why CONTROL ON SCHEMA Is Excluded

CONTROL ON SCHEMA is the schema-level superuser permission. If it were granted, a compromised credential could:
- Destroy entire schemas (hundreds of objects)
- Escalate privileges via GRANT to other accounts
- Transfer schema ownership
- Bypass security controls and audit trails

This model gives Flyway migrations everything they need while preventing catastrophic damage. Individual object drops remain possible; code review, version control and audit logging mitigate them.
