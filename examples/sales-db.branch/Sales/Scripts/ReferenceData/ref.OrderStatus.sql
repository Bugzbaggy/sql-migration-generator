-- Reference data for ref.OrderStatus. Not part of the schema build (a None item in
-- Sales.sqlproj): the migration generator puts these rows into the versioned migration,
-- seeded before anything validates against them.
INSERT INTO [ref].[OrderStatus] ([StatusId], [Name])
VALUES
	(1, 'New'),
	(2, 'Paid'),
	(3, 'Shipped'),
	(4, 'Cancelled');
