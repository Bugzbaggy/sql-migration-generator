-- Rows already in production before the branch deploys: the new NOT NULL column, its
-- default and the foreign key are all validated against them.
SET NOCOUNT ON;
INSERT INTO [sales].[Customer] ([Name], [Email]) VALUES (N'Ada', 'ada@example.com'), (N'Grace', 'grace@example.com');
INSERT INTO [sales].[Order] ([CustomerId], [OrderDate], [Total])
VALUES (1, '2026-10-02', 9.99), (1, '2026-10-03', 25.00), (2, '2026-10-04', 100.00);
