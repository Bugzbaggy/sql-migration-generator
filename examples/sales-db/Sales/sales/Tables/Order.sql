CREATE TABLE [sales].[Order]
(
	[OrderId] INT IDENTITY (1, 1) NOT NULL,
	[CustomerId] INT NOT NULL,
	[OrderDate] DATETIME2 (2) NOT NULL,
	[Total] DECIMAL (12, 2) NOT NULL,
	CONSTRAINT [PK_Order] PRIMARY KEY CLUSTERED ([OrderId] ASC) WITH (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON),
	CONSTRAINT [FK_Order_Customer] FOREIGN KEY ([CustomerId]) REFERENCES [sales].[Customer] ([CustomerId])
);
GO
