# SQL Coding Standards

Follow these project-wide SQL Server standards when generating migration scripts.

## Data Type Standards

| Category | Type | Usage |
|----------|------|-------|
| ASCII text | `VARCHAR(n)` | Default for string data |
| Unicode text | `NVARCHAR(n)` | For internationalized text |
| Small identifiers | `INT` | Standard ID columns |
| Large sequences | `BIGINT` | High-volume counters/sequences |
| Financial (price/cost) | `DECIMAL(12,6)` | Pricing fields |
| Financial (aggregations) | `DECIMAL(18,6)` | Stats table aggregations |
| Timestamps | `DATETIME2(2)` | Default for date+time |
| Date-only | `DATE` | When time is not needed |
| Hourly stats | `SMALLDATETIME` | Hourly aggregation buckets |
| Booleans | `BIT` | True/false values |
| GUIDs | `UNIQUEIDENTIFIER` | UUID/GUID columns |

**Rules**:
- ALWAYS specify length/precision: `VARCHAR(50)` not `VARCHAR`, `DECIMAL(12,6)` not `DECIMAL`
- All columns MUST have explicit `NULL` or `NOT NULL`
- **Deprecated types**: Never use `TEXT`, `NTEXT`, or `IMAGE` — use `VARCHAR(MAX)`, `NVARCHAR(MAX)`, `VARBINARY(MAX)` instead

## Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Schema names | lowercase | `dbo`, `sales`, `ref` |
| Column names | PascalCase, no prefixes | `CountryId`, `CreatedDate` |
| Primary keys | `PK_TableName` | `PK_Customer` |
| Foreign keys | `FK_Table_ReferencedTable` | `FK_Agent_AgentStatus` |
| Unique constraints | `UQ_Table_Column` | `UQ_Agent_Email` |
| Check constraints | `CK_Table_Column` | `CK_Agent_Priority` |
| Default constraints | `DF_Table_Column` | `DF_Agent_IsActive` |
| Indexes | `IX_Table_Column(s)` | `IX_Agent_StatusId` |
| Object naming | Feature/table prefix for co-location | `Agent_Update`, `Agent_GetById` |

## Formatting Rules

- **Indentation**: Tabs (not spaces)
- **Brackets**: Avoid unless required (reserved words, special characters)
- **Trailing spaces**: Remove trailing whitespace
- **Schema references**: Use clean `schema.ObjectName` format (no brackets unless needed)

## Stored Procedure Header Format

All stored procedures, functions, and views in REPEATABLE migrations must preserve the source file's header:

```sql
-- =============================================
-- Author: [Full Engineer Name]
-- Create date: [DD Mon YYYY]
-- Description: [One-line summary]
-- Usage : EXEC schema.ProcedureName @Param = value
-- =============================================
-- Change History
-- =============================================
-- Date        Author   Description
-- --------    -------  ------------------------------------

CREATE OR ALTER PROCEDURE schema.ProcedureName
	@Param INT
AS
BEGIN
	-- procedure body
END
GO
```

**Rules**:
- Never add or change an `Author` line, and never put a tool's name in one
- Preserve existing headers verbatim from source files
- In REPEATABLE migrations use `CREATE OR ALTER` (source files use plain `CREATE`)

## Error Handling

Use `THROW` (never `RAISERROR`). Declare each error number once, under a name that says what
went wrong:

```sql
DECLARE @ErrorCode_InvalidInput INT = 50001;
DECLARE @Error_Message VARCHAR(500);

SET @Error_Message = 'Invalid parameter value';
THROW @ErrorCode_InvalidInput, @Error_Message, 1;
```

**Error numbers**: `THROW` accepts 50000 to 2147483647. Keep one documented list per project,
for example input validation, record not found, a data-consistency failure, and a
linked-server or remote-call failure. Reuse those numbers rather than inventing new ones per
procedure, so callers and alerting can match on them. Avoid a catch-all "generic failure"
number where a specific one exists.

## Transaction Pattern

Always include `SET XACT_ABORT ON` before transactions. Without it, a client timeout (an attention event) leaves the transaction open, holding its locks until the connection closes, and some linked-server errors abort only the statement.

```sql
SET XACT_ABORT ON;

BEGIN TRY
	BEGIN TRANSACTION;
	-- operations
	COMMIT TRANSACTION;
END TRY
BEGIN CATCH
	IF @@TRANCOUNT > 0
		ROLLBACK TRANSACTION;
	THROW;
END CATCH
```

## Schema Qualification

All object references in stored procedures and migration scripts MUST be schema-qualified. Unqualified names resolve to the caller's default schema, which varies by user account — the same query can return different results or error depending on who runs it.

```sql
-- ❌ BAD — resolves differently per user
SELECT OrderId FROM Orders;

-- ✅ GOOD
SELECT OrderId FROM sales.[Order];
```

## Explicit INSERT Column Lists

Never use `INSERT INTO Table VALUES (...)` without column names. It breaks silently when columns are added or reordered.

```sql
-- ❌ BAD
INSERT INTO ref.OrderStatus VALUES (1, 'New');

-- ✅ GOOD
INSERT INTO ref.OrderStatus (StatusId, Name)
VALUES (1, 'New');
```

## EXISTS vs COUNT for Existence Checks

Use `EXISTS` instead of `COUNT(*) > 0`. COUNT scans all matching rows; EXISTS stops at the first match.

```sql
-- ❌ BAD — counts all rows just to check if any exist
IF (SELECT COUNT(*) FROM sales.[Order] WHERE CustomerId = @CustomerId) > 0

-- ✅ GOOD — stops at first match
IF EXISTS (SELECT 1 FROM sales.[Order] WHERE CustomerId = @CustomerId)
```

## SSDT-Derived Anti-Patterns

### SR0001: No SELECT * in Procedures

Never use `SELECT *` — always list explicit columns. SELECT * increases network traffic, prevents covering index usage, and breaks when schema changes.

```sql
-- ❌ BAD
SELECT * FROM sales.[Order] WHERE CustomerId = @CustomerId;

-- ✅ GOOD
SELECT OrderId, CustomerId, OrderDate, Total
FROM sales.[Order] WHERE CustomerId = @CustomerId;
```

**Exceptions**: `EXISTS (SELECT * ...)` and `COUNT(*)` are acceptable.

### SR0009: Use CHAR for Single-Character Columns

`VARCHAR(1)` or `VARCHAR(2)` wastes 2 bytes of overhead per row. Use `CHAR(1)` or `CHAR(2)` for fixed-length short strings.

```sql
-- ❌ BAD
StatusFlag VARCHAR(1) NOT NULL,

-- ✅ GOOD
StatusFlag CHAR(1) NOT NULL,
```

### SR0012: Avoid Reserved Words as Identifiers

Do not use SQL Server reserved words (`Name`, `Type`, `Status`, `User`, `Value`, `Key`, `Date`, `Index`, `Order`) as unbracketed column or object names. If inherited from existing schema, bracket them in migration scripts.

### SR0016: No sp_ Prefix on Stored Procedures

The `sp_` prefix causes SQL Server to search `master` database first, adding overhead and risking name collisions with system procedures.

```sql
-- ❌ BAD
CREATE PROCEDURE dbo.sp_GetCustomerData ...

-- ✅ GOOD
CREATE PROCEDURE dbo.Customer_GetData ...
```

## SARGable Predicates

Never apply functions to columns in WHERE clauses — this prevents index usage:

| Avoid (non-SARGable) | Use Instead |
|-----------------------|-------------|
| `WHERE YEAR(OrderDate) = 2024` | `WHERE OrderDate >= '2024-01-01' AND OrderDate < '2025-01-01'` |
| `WHERE LEFT(CustomerName, 3) = 'ABC'` | `WHERE CustomerName LIKE 'ABC%'` |
| `WHERE ISNULL(Status, 'pending') = 'pending'` | `WHERE (Status = 'pending' OR Status IS NULL)` |
| `WHERE UPPER(Email) = 'TEST@EXAMPLE.COM'` | `WHERE Email = 'test@example.com'` (use CI collation) |

Also extract non-deterministic functions from WHERE clauses into variables (SR0015):

```sql
-- Avoid: GETDATE() evaluated per row
WHERE OrderDate > DATEADD(DAY, -30, GETDATE())

-- Prefer: evaluated once
DECLARE @CutoffDate DATETIME2(2) = DATEADD(DAY, -30, GETDATE());
-- then: WHERE OrderDate > @CutoffDate
```

## Avoid Cursors

Never use `DECLARE ... CURSOR` in stored procedures. Replace with set-based UPDATE/INSERT/DELETE operations for better performance.

## Dynamic SQL

When dynamic SQL is necessary, ALWAYS use `sp_executesql` with parameters. Never use `EXEC(@sql)` or string concatenation with variables — this creates SQL injection vulnerabilities.

```sql
-- Avoid: EXEC with concatenation (SQL injection + no plan caching)
SET @SQL = N'SELECT OrderId, Name FROM Orders WHERE Name = ''' + @Name + '''';
EXEC(@SQL);

-- Prefer: sp_executesql with parameters
SET @SQL = N'SELECT OrderId FROM Orders WHERE Name = @CustomerName';
EXEC sp_executesql @SQL, N'@CustomerName NVARCHAR(100)', @CustomerName = @Name;
```

## Implicit Type Conversions (SR0014)

Avoid implicit type conversions that cause data loss or prevent index usage:
- Match parameter types to column types in stored procedures
- Never assign BIGINT to SMALLINT/TINYINT without explicit CAST with validation
- Avoid comparing VARCHAR parameters against NVARCHAR columns (causes implicit conversion and index scan)

## UPSERT Pattern (No MERGE)

**NEVER use MERGE statements.** MERGE has known race conditions under concurrency, verbose error messages, and documented bugs in SQL Server. Use UPDATE + INSERT:

```sql
UPDATE schema.TableName
SET ColumnA = @ValueA,
	ModifiedDate = GETDATE()
WHERE KeyColumn = @Key;

IF @@ROWCOUNT = 0
BEGIN
	INSERT INTO schema.TableName (KeyColumn, ColumnA, CreatedDate)
	VALUES (@Key, @ValueA, GETDATE());
END
```

## SQL Server 2019+ T-SQL Preferences

### STRING_AGG (SQL Server 2017+)

In stored procedures and functions, prefer `STRING_AGG()` over `FOR XML PATH('')` for string concatenation:

```sql
-- Avoid: FOR XML PATH (legacy pattern)
SELECT STUFF((SELECT ', ' + Name FROM schema.Table FOR XML PATH('')), 1, 2, '')

-- Prefer: STRING_AGG (cleaner, faster, NULL-safe)
SELECT STRING_AGG(Name, ', ') FROM schema.Table
```

### SET NOCOUNT ON

All stored procedures must include `SET NOCOUNT ON;` as the first statement after `BEGIN`. This reduces network traffic and prevents ORM framework interference.

### SCOPE_IDENTITY() vs @@IDENTITY

Never use `@@IDENTITY` — always use `SCOPE_IDENTITY()`. The `@@IDENTITY` function returns identity values from any scope (including trigger inserts), which can return incorrect values. (SSDT rule SR0008)

### Deprecated Join Syntax

Never use `*=` or `=*` (old-style outer join operators). Use `LEFT OUTER JOIN` / `RIGHT OUTER JOIN` instead. (SSDT rule SR0010)

## CREATE vs CREATE OR ALTER

| Context | Syntax |
|---------|--------|
| Source files (the SSDT project folder) | `CREATE PROCEDURE` (plain CREATE for SSDT) |
| Repeatable migrations (`R__`) | `CREATE OR ALTER PROCEDURE` (safe redeployment) |
| Version migrations (`V__`) | Idempotent patterns with IF EXISTS/IF NOT EXISTS |
