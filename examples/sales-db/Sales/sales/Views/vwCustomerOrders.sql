-- =============================================
-- Author: Example Author
-- Create date: 01 Oct 2026
-- Description: Customers with their orders and tax-inclusive totals
-- Usage : SELECT CustomerName, TotalWithTax FROM sales.vwCustomerOrders
-- =============================================
CREATE VIEW [sales].[vwCustomerOrders]
AS
SELECT
	c.[CustomerId],
	c.[Name] AS [CustomerName],
	o.[OrderId],
	o.[OrderDate],
	sales.fnOrderTotal(o.[Total], 0.0800) AS [TotalWithTax]
FROM [sales].[Customer] AS c
	INNER JOIN [sales].[Order] AS o ON o.[CustomerId] = c.[CustomerId];
GO

GRANT SELECT
	ON OBJECT::[sales].[vwCustomerOrders] TO [role_reporting]
	AS [dbo];
GO
