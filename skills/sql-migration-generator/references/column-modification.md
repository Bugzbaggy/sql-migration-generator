# Column Modification with Dependent Objects

When modifying an existing column (changing data type, NULL to NOT NULL, etc.), you MUST handle all dependent objects using a 3-step process.

SQL Server prevents ALTER COLUMN when dependent objects exist — you will get:
> "The object 'ConstraintName' is dependent on column 'ColumnName'"

## Dependent Objects to Check

Before modifying any column, check the source table file for:
- **Unique constraints** (UQ_*)
- **Check constraints** (CK_*)
- **Default constraints** (DF_*)
- **Indexes** (IX_*, PK_*)
- **Foreign keys** FROM this table (FK_*)
- **Computed columns** that reference the column

## 3-Step Process

### Step 1: DROP All Dependent Objects (with IF EXISTS)

```sql
-- Drop foreign keys
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Name')
BEGIN
	ALTER TABLE [schema].[Table] DROP CONSTRAINT [FK_Name];
END
GO

-- Drop indexes
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Name' AND object_id = OBJECT_ID('schema.Table'))
BEGIN
	DROP INDEX [IX_Name] ON [schema].[Table];
END
GO

-- Drop check constraints
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_Name' AND parent_object_id = OBJECT_ID('schema.Table'))
BEGIN
	ALTER TABLE [schema].[Table] DROP CONSTRAINT [CK_Name];
END
GO

-- Drop unique constraints
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_Name' AND type = 'UQ')
BEGIN
	ALTER TABLE [schema].[Table] DROP CONSTRAINT [UQ_Name];
END
GO

-- Drop default constraints
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'DF_Name' AND parent_object_id = OBJECT_ID('schema.Table'))
BEGIN
	ALTER TABLE [schema].[Table] DROP CONSTRAINT [DF_Name];
END
GO
```

### Step 2: MODIFY the Column

```sql
ALTER TABLE [schema].[Table]
ALTER COLUMN [ColumnName] VARCHAR(100) NOT NULL;
GO
```

### Step 3: RECREATE All Dependent Objects (with IF NOT EXISTS)

Recreate in reverse order: defaults → unique → check → computed → indexes → foreign keys.
Use **exact same definitions** from the source file.

```sql
-- Recreate default constraint
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'DF_Name' AND parent_object_id = OBJECT_ID('schema.Table'))
BEGIN
	ALTER TABLE [schema].[Table] ADD CONSTRAINT [DF_Name] DEFAULT ('value') FOR [ColumnName];
END
GO

-- Recreate unique constraint
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_Name' AND type = 'UQ')
BEGIN
	ALTER TABLE [schema].[Table] ADD CONSTRAINT [UQ_Name] UNIQUE NONCLUSTERED ([ColumnName] ASC);
END
GO

-- Recreate check constraint
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_Name' AND parent_object_id = OBJECT_ID('schema.Table'))
BEGIN
	ALTER TABLE [schema].[Table] ADD CONSTRAINT [CK_Name] CHECK (LEN([ColumnName]) >= 3);
END
GO

-- Recreate index with proper options
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Name' AND object_id = OBJECT_ID('schema.Table'))
BEGIN
	CREATE NONCLUSTERED INDEX [IX_Name] ON [schema].[Table] ([ColumnName])
	WITH (
		FILLFACTOR = 95,
		ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF))
	);
END
GO

-- Recreate foreign key
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Name')
BEGIN
	ALTER TABLE [schema].[Table] ADD CONSTRAINT [FK_Name]
		FOREIGN KEY ([ColumnName]) REFERENCES [schema].[ReferencedTable] ([ReferencedColumn]);
END
GO
```

The index in step 3 is rebuilt inside the same transaction as the `ALTER COLUMN`, so it is not
online, whatever its `ONLINE` option says (see "ONLINE after an ALTER of the same table" in
`references/index-standards.md`). Plan the deployment window for a large table accordingly.

## System Catalog Queries for Dependency Checks

```sql
-- Unique constraints
SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_Name' AND type = 'UQ'

-- Default constraints
SELECT 1 FROM sys.default_constraints WHERE name = 'DF_Name' AND parent_object_id = OBJECT_ID('schema.Table')

-- Check constraints
SELECT 1 FROM sys.check_constraints WHERE name = 'CK_Name' AND parent_object_id = OBJECT_ID('schema.Table')

-- Indexes
SELECT 1 FROM sys.indexes WHERE name = 'IX_Name' AND object_id = OBJECT_ID('schema.Table')

-- Foreign keys
SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Name'
```

## Common Scenarios

This process is required when:
- Changing NULL to NOT NULL
- Changing data type (VARCHAR(50) → VARCHAR(100))
- Changing precision (DECIMAL(10,2) → DECIMAL(12,4))
- Changing collation
- Adding/removing IDENTITY

## Wide-Table Rebuilds (many columns dropped at once)

Sometimes a diff replaces most of a table's columns: a mirror table re-shaped against a new
source, say 348 columns down to 30. The delta is still written out **one literal column
per guarded block**. There is no threshold at which enumeration stops being the answer.

### Required

```sql
-- Drop dependent default constraint first
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'DF_Table_UpdatedAt' AND parent_object_id = OBJECT_ID('schema.Table'))
BEGIN
	ALTER TABLE [schema].[Table] DROP CONSTRAINT [DF_Table_UpdatedAt];
END
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE name = 'UpdatedAt' AND object_id = OBJECT_ID('schema.Table'))
BEGIN
	ALTER TABLE [schema].[Table] DROP COLUMN [UpdatedAt];
END
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE name = 'LEGACY_COL_1' AND object_id = OBJECT_ID('schema.Table'))
BEGIN
	ALTER TABLE [schema].[Table] DROP COLUMN [LEGACY_COL_1];
END
GO

-- ... one such block for EVERY remaining removed column, named literally ...
```

### Forbidden

```sql
-- WRONG: derives the drops from the live catalog at run time
DECLARE @KeepCols TABLE (ColName sysname PRIMARY KEY);
INSERT INTO @KeepCols (ColName) SELECT v FROM (VALUES ('Id'), ('EntityId') /* ... */) AS s(v);

DECLARE @DropSql nvarchar(max) = N'';
SELECT @DropSql = @DropSql + N'ALTER TABLE [schema].[Table] DROP COLUMN [' + c.name + N'];' + CHAR(13) + CHAR(10)
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('schema.Table')
	AND NOT EXISTS (SELECT 1 FROM @KeepCols k WHERE k.ColName = c.name);

EXEC sys.sp_executesql @DropSql;   -- all N statements in ONE batch
```

Why this is rejected:

1. **Unreviewable.** The script does not say which columns it drops; the answer lives in
   production's `sys.columns` at deploy time. A reviewer cannot diff intent against effect.
2. **All-or-nothing.** Every generated statement runs inside a single `sp_executesql` batch.
   One failure — a lingering index, a statistic, a dependent constraint — aborts the rest and
   leaves an arbitrary partial column set behind.
3. **Silent no-op.** `IF @DropSql <> N''` skips the whole operation if the concatenation ever
   yields `NULL`, and the migration still reports success.
4. **Permanent drift.** The generator diffs the **source file**, not the deployed table. Columns
   the batch failed to drop never appear in a future diff, so nothing will ever drop them; an
   SSDT schema compare or publish then proposes dropping them out of band.
5. It violates self-validation checks #19 (no `sp_executesql` over concatenated DDL) and #32.

### Alternative for a full rebuild

If the table really is being rebuilt end to end and its data is disposable, two sequential
branches are cleaner. The first deletes the table's source file, and the generator emits
`DROP TABLE`. The second re-adds it, and the generator emits a plain `CREATE TABLE` in the
source file's column order. That leaves no ALTER delta and no drift. Base both branches on the
branch your pipeline deploys from, and deploy the first before you open the second. Only take
this route when the table's data can be discarded; otherwise enumerate the drops as above.
