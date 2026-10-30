-- Migration generated for branch: initial

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'role_reporting' AND type = 'R')
BEGIN
	CREATE ROLE [role_reporting] AUTHORIZATION [dbo];
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'ref')
BEGIN
	EXEC('CREATE SCHEMA [ref] AUTHORIZATION [dbo]');
END
GO

GRANT ALTER ON SCHEMA::[ref] TO [role_app_ci];
GO
GRANT SELECT ON SCHEMA::[ref] TO [role_app_ci];
GO
GRANT INSERT ON SCHEMA::[ref] TO [role_app_ci];
GO
GRANT UPDATE ON SCHEMA::[ref] TO [role_app_ci];
GO
GRANT DELETE ON SCHEMA::[ref] TO [role_app_ci];
GO
GRANT EXECUTE ON SCHEMA::[ref] TO [role_app_ci];
GO
GRANT REFERENCES ON SCHEMA::[ref] TO [role_app_ci];
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'sales')
BEGIN
	EXEC('CREATE SCHEMA [sales] AUTHORIZATION [dbo]');
END
GO

GRANT ALTER ON SCHEMA::[sales] TO [role_app_ci];
GO
GRANT SELECT ON SCHEMA::[sales] TO [role_app_ci];
GO
GRANT INSERT ON SCHEMA::[sales] TO [role_app_ci];
GO
GRANT UPDATE ON SCHEMA::[sales] TO [role_app_ci];
GO
GRANT DELETE ON SCHEMA::[sales] TO [role_app_ci];
GO
GRANT EXECUTE ON SCHEMA::[sales] TO [role_app_ci];
GO
GRANT REFERENCES ON SCHEMA::[sales] TO [role_app_ci];
GO

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'[sales].[Customer]') AND type = 'U')
BEGIN
	CREATE TABLE [sales].[Customer]
	(
		[CustomerId] INT IDENTITY (1, 1) NOT NULL,
		[Name] NVARCHAR (200) NOT NULL,
		[Email] VARCHAR (320) NULL,
		[CreatedDate] DATETIME2 (2) NOT NULL CONSTRAINT [DF_Customer_CreatedDate] DEFAULT (SYSUTCDATETIME()),
		CONSTRAINT [PK_Customer] PRIMARY KEY CLUSTERED ([CustomerId] ASC) WITH (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON)
	);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'[sales].[Order]') AND type = 'U')
BEGIN
	CREATE TABLE [sales].[Order]
	(
		[OrderId] INT IDENTITY (1, 1) NOT NULL,
		[CustomerId] INT NOT NULL,
		[OrderDate] DATETIME2 (2) NOT NULL,
		[Total] DECIMAL (12, 2) NOT NULL,
		CONSTRAINT [PK_Order] PRIMARY KEY CLUSTERED ([OrderId] ASC) WITH (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON),
		CONSTRAINT [FK_Order_Customer] FOREIGN KEY ([CustomerId]) REFERENCES [sales].[Customer] ([CustomerId])
	);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.synonyms WHERE name = 'Currency' AND schema_id = SCHEMA_ID('ref'))
BEGIN
	CREATE SYNONYM [ref].[Currency] FOR AppCatalog.[geo].[Currency];
END
GO
