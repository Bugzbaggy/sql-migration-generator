-- Drop sales.Customer_GetLegacy
DROP PROCEDURE IF EXISTS [sales].[Customer_GetLegacy];
GO

-- =============================================
-- Author: Example Author
-- Create date: 01 Oct 2026
-- Description: Order total including tax, rounded to cents
-- Usage : SELECT sales.fnOrderTotal(100.00, 0.0800)
-- =============================================
-- Change History
-- =============================================
-- Date        Author          Description
-- --------    -------         ------------------------------------
-- 30 Oct 2026  Example Author   Truncate to cents instead of rounding

CREATE OR ALTER FUNCTION [sales].[fnOrderTotal]
(
	@Total DECIMAL (12, 2),
	@TaxRate DECIMAL (5, 4)
)
RETURNS DECIMAL (12, 2)
AS
BEGIN
	RETURN ROUND(@Total * (1 + @TaxRate), 2, 1);
END
GO

-- =============================================
-- Author: Example Author
-- Create date: 30 Oct 2026
-- Description: Orders with their status name and tax-inclusive total
-- Usage : SELECT OrderId, StatusName FROM sales.vwOrderStatus
-- =============================================
CREATE OR ALTER VIEW [sales].[vwOrderStatus]
AS
SELECT
	o.[OrderId],
	o.[CustomerId],
	s.[Name] AS [StatusName],
	sales.fnOrderTotal(o.[Total], 0.0800) AS [TotalWithTax]
FROM [sales].[Order] AS o
	INNER JOIN [ref].[OrderStatus] AS s ON s.[StatusId] = o.[StatusId];
GO

GRANT SELECT
	ON OBJECT::[sales].[vwOrderStatus] TO [role_reporting]
	AS [dbo];
GO

-- =============================================
-- Author: Example Author
-- Create date: 30 Oct 2026
-- Description: Orders in one status
-- Usage : EXEC sales.Order_GetByStatus @StatusName = 'Paid'
-- =============================================
CREATE OR ALTER PROCEDURE [sales].[Order_GetByStatus]
	@StatusName VARCHAR (30)
AS
BEGIN
	SET NOCOUNT ON;

	SELECT v.[OrderId], v.[CustomerId], v.[StatusName], v.[TotalWithTax]
	FROM [sales].[vwOrderStatus] AS v
	WHERE v.[StatusName] = @StatusName;
END
GO

GRANT EXECUTE
	ON OBJECT::[sales].[Order_GetByStatus] TO [role_reporting]
	AS [dbo];
GO

GRANT SELECT
	ON OBJECT::[ref].[OrderStatus] TO [role_reporting]
	AS [dbo];
GO

CREATE OR ALTER TRIGGER [sales].[trg_Order_StatusAudit]
	ON [sales].[Order]
	AFTER UPDATE
AS
BEGIN
	SET NOCOUNT ON;

	INSERT INTO [audit].[OrderChange] ([OrderId], [OldStatusId], [NewStatusId])
	SELECT i.[OrderId], d.[StatusId], i.[StatusId]
	FROM inserted AS i
		INNER JOIN deleted AS d ON d.[OrderId] = i.[OrderId]
	WHERE d.[StatusId] <> i.[StatusId];
END
GO
