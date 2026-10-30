-- Migration generated for branch: feature.order-status

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'audit')
BEGIN
	EXEC('CREATE SCHEMA [audit] AUTHORIZATION [dbo]');
END
GO

GRANT ALTER ON SCHEMA::[audit] TO [role_app_ci];
GO

GRANT SELECT ON SCHEMA::[audit] TO [role_app_ci];
GO

GRANT INSERT ON SCHEMA::[audit] TO [role_app_ci];
GO

GRANT UPDATE ON SCHEMA::[audit] TO [role_app_ci];
GO

GRANT DELETE ON SCHEMA::[audit] TO [role_app_ci];
GO

GRANT EXECUTE ON SCHEMA::[audit] TO [role_app_ci];
GO

GRANT REFERENCES ON SCHEMA::[audit] TO [role_app_ci];
GO

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'[ref].[OrderStatus]') AND type = 'U')
BEGIN
	CREATE TABLE [ref].[OrderStatus]
	(
		[StatusId] TINYINT NOT NULL,
		[Name] VARCHAR (30) NOT NULL,
		CONSTRAINT [PK_OrderStatus] PRIMARY KEY CLUSTERED ([StatusId] ASC),
		CONSTRAINT [UQ_OrderStatus_Name] UNIQUE NONCLUSTERED ([Name] ASC)
	);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'[audit].[OrderChange]') AND type = 'U')
BEGIN
	CREATE TABLE [audit].[OrderChange]
	(
		[OrderChangeId] BIGINT IDENTITY (1, 1) NOT NULL,
		[OrderId] INT NOT NULL,
		[OldStatusId] TINYINT NULL,
		[NewStatusId] TINYINT NOT NULL,
		[ChangedAt] DATETIME2 (2) NOT NULL CONSTRAINT [DF_OrderChange_ChangedAt] DEFAULT (SYSUTCDATETIME()),
		CONSTRAINT [PK_OrderChange] PRIMARY KEY CLUSTERED ([OrderChangeId] ASC) WITH (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON)
	);
END
GO

-- Seed ref.OrderStatus before sales.Order validates its rows against it (error 547 otherwise)
INSERT INTO [ref].[OrderStatus] ([StatusId], [Name])
SELECT src.[StatusId], src.[Name]
FROM (VALUES
	(1, 'New'),
	(2, 'Paid'),
	(3, 'Shipped'),
	(4, 'Cancelled')
) AS src ([StatusId], [Name])
WHERE NOT EXISTS (
	SELECT 1 FROM [ref].[OrderStatus] AS x WHERE x.[StatusId] = src.[StatusId]
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE name = 'StatusId' AND object_id = OBJECT_ID('[sales].[Order]'))
BEGIN
	ALTER TABLE [sales].[Order] ADD [StatusId] TINYINT NOT NULL CONSTRAINT [DF_Order_StatusId] DEFAULT ((1));
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Order_CustomerId_OrderDate' AND object_id = OBJECT_ID('[sales].[Order]'))
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

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Order_OrderStatus')
BEGIN
	ALTER TABLE [sales].[Order] ADD CONSTRAINT [FK_Order_OrderStatus]
		FOREIGN KEY ([StatusId]) REFERENCES [ref].[OrderStatus] ([StatusId]);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.synonyms WHERE name = 'Country' AND schema_id = SCHEMA_ID('ref'))
BEGIN
	CREATE SYNONYM [ref].[Country] FOR AppCatalog.[geo].[Country];
END
GO
