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

CREATE OR ALTER FUNCTION [sales].[fnOrderTotal]
(
	@Total DECIMAL (12, 2),
	@TaxRate DECIMAL (5, 4)
)
RETURNS DECIMAL (12, 2)
AS
BEGIN
	RETURN ROUND(@Total * (1 + @TaxRate), 2);
END
GO

-- =============================================
-- Author: Example Author
-- Create date: 01 Oct 2026
-- Description: Customers with their orders and tax-inclusive totals
-- Usage : SELECT CustomerName, TotalWithTax FROM sales.vwCustomerOrders
-- =============================================
CREATE OR ALTER VIEW [sales].[vwCustomerOrders]
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

-- =============================================
-- Author: Example Author
-- Create date: 01 Oct 2026
-- Description: Gets one customer
-- Usage : EXEC sales.Customer_Get @CustomerId = 1
-- =============================================
CREATE OR ALTER PROCEDURE [sales].[Customer_Get]
	@CustomerId INT
AS
BEGIN
	SET NOCOUNT ON;

	SELECT c.[CustomerId], c.[Name], c.[Email], c.[CreatedDate]
	FROM [sales].[Customer] AS c
	WHERE c.[CustomerId] = @CustomerId;
END
GO

GRANT EXECUTE
	ON OBJECT::[sales].[Customer_Get] TO [role_reporting]
	AS [dbo];
GO

-- =============================================
-- Author: Example Author
-- Create date: 01 Oct 2026
-- Description: Looks a customer up by e-mail (superseded; removed on the branch)
-- Usage : EXEC sales.Customer_GetLegacy @Email = 'someone@example.com'
-- =============================================
CREATE OR ALTER PROCEDURE [sales].[Customer_GetLegacy]
	@Email VARCHAR (320)
AS
BEGIN
	SET NOCOUNT ON;

	SELECT c.[CustomerId], c.[Name]
	FROM [sales].[Customer] AS c
	WHERE c.[Email] = @Email;
END
GO

GRANT EXECUTE
	ON OBJECT::[sales].[Customer_GetLegacy] TO [role_reporting]
	AS [dbo];
GO
