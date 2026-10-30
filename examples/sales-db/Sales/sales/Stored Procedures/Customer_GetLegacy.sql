-- =============================================
-- Author: Example Author
-- Create date: 01 Oct 2026
-- Description: Looks a customer up by e-mail (superseded; removed on the branch)
-- Usage : EXEC sales.Customer_GetLegacy @Email = 'someone@example.com'
-- =============================================
CREATE PROCEDURE [sales].[Customer_GetLegacy]
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
