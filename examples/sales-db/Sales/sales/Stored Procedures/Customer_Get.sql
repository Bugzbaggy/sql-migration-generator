-- =============================================
-- Author: Example Author
-- Create date: 01 Oct 2026
-- Description: Gets one customer
-- Usage : EXEC sales.Customer_Get @CustomerId = 1
-- =============================================
CREATE PROCEDURE [sales].[Customer_Get]
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
