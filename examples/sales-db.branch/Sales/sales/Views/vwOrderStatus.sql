-- =============================================
-- Author: Example Author
-- Create date: 30 Oct 2026
-- Description: Orders with their status name and tax-inclusive total
-- Usage : SELECT OrderId, StatusName FROM sales.vwOrderStatus
-- =============================================
CREATE VIEW [sales].[vwOrderStatus]
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
