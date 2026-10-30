-- The upgraded database after the branch deployed (and its scripts ran a second time).
SET NOCOUNT ON;

IF (SELECT COUNT(*) FROM [ref].[OrderStatus]) <> 4
	THROW 50001, 'ref.OrderStatus should hold exactly the 4 seeded rows (a second run must not duplicate them)', 1;

IF EXISTS (SELECT 1 FROM [sales].[Order] WHERE [StatusId] <> 1) OR (SELECT COUNT(*) FROM [sales].[Order]) <> 3
	THROW 50002, 'existing orders should keep their 3 rows with the default StatusId 1', 1;

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Order_OrderStatus' AND is_not_trusted = 0)
	THROW 50003, 'FK_Order_OrderStatus should exist and be trusted', 1;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Order_CustomerId_OrderDate' AND object_id = OBJECT_ID('sales.Order') AND fill_factor = 95)
	THROW 50004, 'IX_Order_CustomerId_OrderDate should exist with FILLFACTOR 95', 1;

IF OBJECT_ID('sales.Customer_GetLegacy') IS NOT NULL
	THROW 50005, 'sales.Customer_GetLegacy should have been dropped', 1;

IF NOT EXISTS (SELECT 1 FROM sys.synonyms WHERE name = 'Country' AND base_object_name = '[AppCatalog].[geo].[Country]')
	THROW 50006, 'ref.Country should point at AppCatalog.geo.Country (the Catalog SQLCMD variable, mapped)', 1;

IF NOT EXISTS (SELECT 1 FROM sys.database_permissions AS p JOIN sys.database_principals AS r ON r.principal_id = p.grantee_principal_id
	WHERE r.name = 'role_app_ci' AND p.class_desc = 'SCHEMA' AND SCHEMA_NAME(p.major_id) = 'audit' AND p.permission_name = 'ALTER')
	THROW 50007, 'role_app_ci should hold ALTER on the new audit schema', 1;

IF NOT EXISTS (SELECT 1 FROM sys.database_permissions AS p JOIN sys.database_principals AS r ON r.principal_id = p.grantee_principal_id
	WHERE r.name = 'role_reporting' AND p.major_id = OBJECT_ID('sales.Order_GetByStatus') AND p.permission_name = 'EXECUTE')
	THROW 50008, 'role_reporting should hold EXECUTE on sales.Order_GetByStatus', 1;

-- 9.99 * 1.08 = 10.7892: the branch truncates (10.78) where main rounded (10.79).
IF [sales].[fnOrderTotal](9.99, 0.0800) <> 10.78
	THROW 50009, 'sales.fnOrderTotal should be the branch version (truncating)', 1;

-- The trigger that the table file defines audits a status change.
UPDATE [sales].[Order] SET [StatusId] = 2 WHERE [OrderId] = 1;
IF (SELECT COUNT(*) FROM [audit].[OrderChange] WHERE [OrderId] = 1 AND [OldStatusId] = 1 AND [NewStatusId] = 2) <> 1
	THROW 50010, 'trg_Order_StatusAudit should log the status change', 1;

DECLARE @Paid TABLE ([OrderId] INT, [CustomerId] INT, [StatusName] VARCHAR(30), [TotalWithTax] DECIMAL(12, 2));
INSERT INTO @Paid EXEC [sales].[Order_GetByStatus] @StatusName = 'Paid';
IF (SELECT COUNT(*) FROM @Paid) <> 1
	THROW 50011, 'sales.Order_GetByStatus should return the one paid order', 1;

PRINT 'All assertions passed.';
