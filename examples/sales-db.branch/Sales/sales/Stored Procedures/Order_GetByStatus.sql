-- =============================================
-- Author: Example Author
-- Create date: 30 Oct 2026
-- Description: Orders in one status
-- Usage : EXEC sales.Order_GetByStatus @StatusName = 'Paid'
-- =============================================
CREATE PROCEDURE [sales].[Order_GetByStatus]
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
