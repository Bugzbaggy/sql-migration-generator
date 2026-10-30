# Index Creation Standards

All indexes in VERSION migration scripts MUST include FILLFACTOR and ONLINE options for production safety.

**CRITICAL — SQL Server Syntax Distinction:**
`WAIT_AT_LOW_PRIORITY` and `RESUMABLE` are **only valid** for `CREATE INDEX` and `ALTER INDEX REBUILD`. They are **NOT valid** for `ALTER TABLE ... ADD CONSTRAINT` (PK or UQ). Using them in ALTER TABLE causes Flyway error: `'WAIT_AT_LOW_PRIORITY' is not a recognized ALTER TABLE option.`

## FILLFACTOR Requirements

| Index Type | FILLFACTOR | Reason |
|------------|-----------|--------|
| Primary Keys (Clustered) | 90 | More frequent updates need more free space |
| Clustered Indexes | 90 | Same as PKs — higher write activity |
| Non-Clustered Indexes | 95 | Less frequent updates, tighter packing |
| Unique Constraints (Non-Clustered) | 95 | Treated as non-clustered indexes |

## ONLINE Options

The ONLINE option syntax differs by statement type:

### For CREATE INDEX / ALTER INDEX REBUILD (full syntax)

```sql
ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF))
```

- **ONLINE = ON**: Allows table reads/writes during index creation (no downtime)
- **WAIT_AT_LOW_PRIORITY**: Waits at low priority for locks, minimizing blocking
- **MAX_DURATION = 5 MINUTES**: Maximum wait time before action
- **ABORT_AFTER_WAIT = SELF**: Aborts the index operation (not user queries) if wait exceeds duration

### For ALTER TABLE ADD CONSTRAINT (flat syntax only)

```sql
ONLINE = ON
```

- `ALTER TABLE ... ADD CONSTRAINT ... PRIMARY KEY` and `ALTER TABLE ... ADD CONSTRAINT ... UNIQUE` support **only** `ONLINE = ON` (flat)
- **DO NOT** use `ONLINE = ON (WAIT_AT_LOW_PRIORITY ...)` — SQL Server rejects it with error 155
- **DO NOT** use `RESUMABLE = ON` — not recognized for ALTER TABLE

## OPTIMIZE_FOR_SEQUENTIAL_KEY (SQL Server 2019+)

When a clustered index or primary key is on an IDENTITY or SEQUENCE column, add `OPTIMIZE_FOR_SEQUENTIAL_KEY = ON` to reduce last-page insert contention under high-concurrency workloads.

| Scenario | Apply OPTIMIZE_FOR_SEQUENTIAL_KEY? |
|----------|-----------------------------------|
| PK on IDENTITY column | YES |
| PK on SEQUENCE column | YES |
| PK on natural key (e.g., composite business key) | NO |
| Non-clustered index on non-identity column | NO |

This option applies to both inline PK inside `CREATE TABLE` and standalone `ALTER TABLE ADD CONSTRAINT PK_...`.

## RESUMABLE — NOT Allowed in Flyway Migrations

**DO NOT** use `RESUMABLE = ON` in any Flyway version migration script. SQL Server error 574: `RESUMABLE INDEX statement cannot be used inside a user transaction.` Flyway wraps all version migrations in an implicit transaction, making RESUMABLE incompatible.

- `RESUMABLE = ON` works only outside of transactions (e.g., ad-hoc maintenance scripts)
- For Flyway migrations, rely on `ONLINE = ON (WAIT_AT_LOW_PRIORITY ...)` for non-blocking index builds
- If an index build is interrupted, the migration will fail and can be retried by Flyway

## Valid Options by Statement Type

| Option | `CREATE INDEX` | `ALTER INDEX REBUILD` | `ALTER TABLE ADD CONSTRAINT PK/UQ` | Inline PK in `CREATE TABLE` |
|--------|:-:|:-:|:-:|:-:|
| FILLFACTOR | YES | YES | YES | NO |
| ONLINE = ON (flat) | YES | YES | YES | NO |
| WAIT_AT_LOW_PRIORITY | YES | YES | **NO** | NO |
| RESUMABLE | **NO** (Flyway txn) | **NO** (Flyway txn) | **NO** | NO |
| OPTIMIZE_FOR_SEQUENTIAL_KEY | YES | N/A | YES | YES |

## Patterns

### Primary Key (Clustered) via ALTER TABLE — on IDENTITY Column

```sql
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'PK_TableName'
               AND object_id = OBJECT_ID('schema.TableName'))
BEGIN
	ALTER TABLE [schema].[TableName]
	ADD CONSTRAINT [PK_TableName] PRIMARY KEY CLUSTERED ([ColumnName])
	WITH (
		FILLFACTOR = 90,
		OPTIMIZE_FOR_SEQUENTIAL_KEY = ON,
		ONLINE = ON
	);
END
GO
```

Note: Omit `OPTIMIZE_FOR_SEQUENTIAL_KEY = ON` if the key column is NOT an IDENTITY or SEQUENCE column.

### Primary Key (Clustered) via ALTER TABLE — on Natural/Composite Key

```sql
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'PK_TableName' AND type = 'PK')
BEGIN
	ALTER TABLE [schema].[TableName]
	ADD CONSTRAINT [PK_TableName] PRIMARY KEY CLUSTERED ([Col1] ASC, [Col2] ASC)
	WITH (
		FILLFACTOR = 90,
		ONLINE = ON
	);
END
GO
```

### Non-Clustered Index (CREATE INDEX)

```sql
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Table_Column'
               AND object_id = OBJECT_ID('schema.TableName'))
BEGIN
	CREATE NONCLUSTERED INDEX [IX_Table_Column]
	ON [schema].[TableName] ([ColumnName] ASC)
	WITH (
		FILLFACTOR = 95,
		ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF))
	);
END
GO
```

### Unique Constraint (Non-Clustered) via ALTER TABLE

```sql
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_Table_Column' AND type = 'UQ')
BEGIN
	ALTER TABLE [schema].[TableName]
	ADD CONSTRAINT [UQ_Table_Column] UNIQUE NONCLUSTERED ([ColumnName] ASC)
	WITH (
		FILLFACTOR = 95,
		ONLINE = ON
	);
END
GO
```

### Covering Index with INCLUDE Columns (CREATE INDEX)

A covering index includes all columns needed by a query, eliminating expensive key lookups to the clustered index. Place columns used in WHERE/JOIN/ORDER BY as key columns; columns only returned in SELECT go in INCLUDE.

```sql
-- Query: SELECT Total FROM sales.[Order]
--        WHERE CustomerId = @id ORDER BY OrderDate
-- Key columns: CustomerId (WHERE), OrderDate (ORDER BY)
-- INCLUDE columns: Total (only in SELECT)

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Order_CustomerId_OrderDate'
               AND object_id = OBJECT_ID('sales.[Order]'))
BEGIN
	CREATE NONCLUSTERED INDEX [IX_Order_CustomerId_OrderDate]
	ON [sales].[Order] ([CustomerId] ASC, [OrderDate] ASC)
	INCLUDE ([Total])
	WITH (
		FILLFACTOR = 95,
		ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF))
	);
END
GO
```

**Trade-offs**: Each INCLUDE column adds storage and write overhead. Only add INCLUDE columns for high-frequency query patterns verified by Query Store or missing index DMVs.

## ONLINE After an ALTER of the Same Table (SQL Server message 1970)

Flyway runs each versioned script in one transaction. If the script first alters a table
(`ALTER TABLE ... ADD`, `ALTER COLUMN`, a constraint) and then builds an index on it with
`ONLINE = ON`, the ALTER's schema-modification lock is still held when the build starts. SQL
Server proceeds, but it warns:

> Online index operation on table '...' will proceed but concurrent access to the table may be
> limited due to residual lock on the table from a previous operation in the same transaction.

Readers and writers wait for the whole build to finish, so the index is offline in all but name.
`sqlmig check` warns when a script does this. It is harmless on a small table. On a large or
busy one, put the index in a migration of its own, in a later branch, so its transaction holds no
earlier lock. A table the same script creates is exempt: nothing else can be using it yet.

## ONLINE After an ALTER of the Same Table (SQL Server message 1970)

Flyway runs each versioned script in one transaction. If the script first alters a table
(`ALTER TABLE ... ADD`, `ALTER COLUMN`, a constraint) and then builds an index on it with
`ONLINE = ON`, the ALTER's schema-modification lock is still held when the build starts. SQL
Server proceeds, but it warns:

> Online index operation on table '...' will proceed but concurrent access to the table may be
> limited due to residual lock on the table from a previous operation in the same transaction.

Readers and writers wait for the whole build to finish, so the index is offline in all but name.
`sqlmig check` warns when a script does this. It is harmless on a small table. On a large or
busy one, put the index in a migration of its own, in a later branch, so its transaction holds no
earlier lock. A table the same script creates is exempt: nothing else can be using it yet.

## Exception: Inline PRIMARY KEY in CREATE TABLE

When the PRIMARY KEY is defined **inline** within a `CREATE TABLE` statement, FILLFACTOR and ONLINE options are NOT required. However, `OPTIMIZE_FOR_SEQUENTIAL_KEY` DOES apply inline when the PK column is IDENTITY:

```sql
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'[schema].[TableName]') AND type = 'U')
BEGIN
	CREATE TABLE [schema].[TableName] (
		Id INT IDENTITY(1,1) NOT NULL,
		Name VARCHAR(100) NOT NULL,
		CONSTRAINT [PK_TableName] PRIMARY KEY CLUSTERED (Id)
			WITH (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON)
	);
END
GO
```

FILLFACTOR/ONLINE options are only required when creating indexes on **existing tables** via ALTER TABLE or CREATE INDEX statements. OPTIMIZE_FOR_SEQUENTIAL_KEY can be used both inline and on existing tables. RESUMABLE is NOT allowed in Flyway migrations (error 574).
