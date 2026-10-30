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

CREATE FUNCTION [sales].[fnOrderTotal]
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
