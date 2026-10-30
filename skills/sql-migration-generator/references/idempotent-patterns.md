# Idempotent Patterns for Version Migrations

ALL Version migration objects MUST use these patterns. Every pattern uses `IF EXISTS`/`IF NOT EXISTS` wrapped in `BEGIN`/`END` + `GO` blocks.

A versioned script must survive a second run. Flyway runs it once, but people re-run a script by hand after a partial failure. The `sqlmig` end-to-end test deploys every versioned script twice to prove it.

## Tables

```sql
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'[schema].[TableName]') AND type = 'U')
BEGIN
	CREATE TABLE [schema].[TableName] (
		-- columns and constraints
	)
END
GO
```

## Indexes

**Non-Clustered** (FILLFACTOR = 95):

```sql
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IndexName' AND object_id = OBJECT_ID('schema.TableName'))
BEGIN
	CREATE NONCLUSTERED INDEX [IX_IndexName] ON [schema].[TableName] (
		[ColumnName] ASC
	)
	WITH (
		FILLFACTOR = 95,
		ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF))
	);
END
GO
```

**Primary Key on existing table** (FILLFACTOR = 90):

```sql
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'PK_TableName' AND object_id = OBJECT_ID('schema.TableName'))
BEGIN
	ALTER TABLE [schema].[TableName]
	ADD CONSTRAINT [PK_TableName] PRIMARY KEY CLUSTERED ([ColumnName])
	WITH (
		FILLFACTOR = 90,
		OPTIMIZE_FOR_SEQUENTIAL_KEY = ON,  -- omit if key column is NOT IDENTITY or SEQUENCE
		ONLINE = ON
	);
END
GO
```

Note: `ALTER TABLE ADD CONSTRAINT` only supports `ONLINE = ON` (flat). Do NOT use `WAIT_AT_LOW_PRIORITY` or `RESUMABLE` — those are only valid for `CREATE INDEX` / `ALTER INDEX REBUILD`.

See `references/index-standards.md` for detailed requirements and exceptions.

## Foreign Keys

```sql
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_ForeignKeyName')
BEGIN
	ALTER TABLE [schema].[TableName] ADD CONSTRAINT [FK_ForeignKeyName]
		FOREIGN KEY ([ColumnName]) REFERENCES [schema].[ReferencedTable] ([ReferencedColumn])
END
GO
```

## Synonyms

```sql
IF NOT EXISTS (SELECT 1 FROM sys.synonyms WHERE name = 'SynonymName' AND schema_id = SCHEMA_ID('schema'))
BEGIN
	CREATE SYNONYM [schema].[SynonymName] FOR TargetDatabase.targetschema.targetobject
END
GO
```

## User-Defined Types (UDTs)

```sql
IF NOT EXISTS (SELECT 1 FROM sys.types WHERE name = 'TypeName' AND schema_id = SCHEMA_ID('schema') AND is_user_defined = 1)
BEGIN
	CREATE TYPE [schema].[TypeName] FROM NVARCHAR(100) NOT NULL
END
GO
```

## Sequences

```sql
IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE name = 'SequenceName' AND schema_id = SCHEMA_ID('schema'))
BEGIN
	CREATE SEQUENCE [schema].[SequenceName] AS BIGINT START WITH 1 INCREMENT BY 1
END
GO
```

## Default Constraints

```sql
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'DF_ConstraintName' AND parent_object_id = OBJECT_ID('schema.TableName'))
BEGIN
	ALTER TABLE [schema].[TableName] ADD CONSTRAINT [DF_ConstraintName] DEFAULT (value) FOR [ColumnName]
END
GO
```

## Check Constraints

```sql
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_ConstraintName' AND parent_object_id = OBJECT_ID('schema.TableName'))
BEGIN
	ALTER TABLE [schema].[TableName] ADD CONSTRAINT [CK_ConstraintName] CHECK (expression)
END
GO
```

## Unique Constraints

```sql
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_ConstraintName' AND type = 'UQ')
BEGIN
	ALTER TABLE [schema].[TableName] ADD CONSTRAINT [UQ_ConstraintName] UNIQUE NONCLUSTERED ([ColumnName] ASC)
	WITH (
		FILLFACTOR = 95,
		ONLINE = ON
	);
END
GO
```

Note: `ALTER TABLE ADD CONSTRAINT UNIQUE` only supports `ONLINE = ON` (flat). Do NOT use `WAIT_AT_LOW_PRIORITY` or `RESUMABLE` — those are only valid for `CREATE INDEX` / `ALTER INDEX REBUILD`.

## Roles

```sql
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'role_name' AND type = 'R')
BEGIN
	CREATE ROLE [role_name] AUTHORIZATION [dbo];
END
GO
```

## Schemas (CREATE SCHEMA must be alone in its batch, hence EXEC)

```sql
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'schema')
BEGIN
	EXEC('CREATE SCHEMA [schema] AUTHORIZATION [dbo]');
END
GO
```

## GRANTs (Schema-Level in Version Migrations)

```sql
GRANT ALTER ON SCHEMA::[schema] TO [<ciRole>];
GO
```

A GRANT is idempotent on its own: granting what is already granted is a no-op.

## GRANTs (Object-Level — for Repeatable Migrations Only)

```sql
GRANT EXECUTE ON OBJECT::[schema].[ObjectName] TO [role_name];
GO
```

## Reference Data Inserts

**CRITICAL**: Do NOT wrap multi-row INSERT inside a single IF NOT EXISTS check. Each row must be checked individually.

### WRONG Pattern

```sql
-- ❌ Only checks ONE row, inserts ALL or NONE.
-- If 'v1' exists but 'v2' does not, 'v2' is NEVER inserted!
IF NOT EXISTS (SELECT 1 FROM table WHERE KeyCol = 'v1')
BEGIN
	INSERT INTO table (KeyCol, Name) VALUES ('v1', 'd1'), ('v2', 'd2');
END
```

### CORRECT Pattern

```sql
-- ✅ Each row checked individually via anti-join
INSERT INTO [schema].[TableName] (KeyCol, Col2)
SELECT src.KeyCol, src.Col2
FROM (VALUES
	('v1', 'd1'),
	('v2', 'd2'),
	('v3', 'd3')
) AS src(KeyCol, Col2)
WHERE NOT EXISTS (
	SELECT 1 FROM [schema].[TableName] x WHERE x.KeyCol = src.KeyCol
);
GO
```

## DROP Patterns (for Deleted Objects)

### Drop Table

```sql
IF EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'[schema].[TableName]') AND type = 'U')
BEGIN
	DROP TABLE [schema].[TableName];
END
GO
```

### Drop Synonym

```sql
IF EXISTS (SELECT 1 FROM sys.synonyms WHERE name = 'SynonymName' AND schema_id = SCHEMA_ID('schema'))
BEGIN
	DROP SYNONYM [schema].[SynonymName];
END
GO
```

### Drop Index

```sql
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IndexName' AND object_id = OBJECT_ID('schema.TableName'))
BEGIN
	DROP INDEX [IX_IndexName] ON [schema].[TableName];
END
GO
```

### Drop Foreign Key

```sql
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_ForeignKeyName')
BEGIN
	ALTER TABLE [schema].[TableName] DROP CONSTRAINT [FK_ForeignKeyName];
END
GO
```

### Drop Default Constraint

```sql
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'DF_ConstraintName' AND parent_object_id = OBJECT_ID('schema.TableName'))
BEGIN
	ALTER TABLE [schema].[TableName] DROP CONSTRAINT [DF_ConstraintName];
END
GO
```

### Drop Check Constraint

```sql
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_ConstraintName' AND parent_object_id = OBJECT_ID('schema.TableName'))
BEGIN
	ALTER TABLE [schema].[TableName] DROP CONSTRAINT [CK_ConstraintName];
END
GO
```

### Drop Trigger (before dropping parent table)

```sql
IF EXISTS (SELECT 1 FROM sys.triggers WHERE name = 'TriggerName')
BEGIN
	DROP TRIGGER [schema].[TriggerName];
END
GO
```
