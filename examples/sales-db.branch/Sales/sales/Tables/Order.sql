CREATE TABLE [sales].[Order]
(
	[OrderId] INT IDENTITY (1, 1) NOT NULL,
	[CustomerId] INT NOT NULL,
	[OrderDate] DATETIME2 (2) NOT NULL,
	[Total] DECIMAL (12, 2) NOT NULL,
	[StatusId] TINYINT NOT NULL CONSTRAINT [DF_Order_StatusId] DEFAULT ((1)),
	CONSTRAINT [PK_Order] PRIMARY KEY CLUSTERED ([OrderId] ASC) WITH (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON),
	CONSTRAINT [FK_Order_Customer] FOREIGN KEY ([CustomerId]) REFERENCES [sales].[Customer] ([CustomerId]),
	CONSTRAINT [FK_Order_OrderStatus] FOREIGN KEY ([StatusId]) REFERENCES [ref].[OrderStatus] ([StatusId])
);
GO

CREATE NONCLUSTERED INDEX [IX_Order_CustomerId_OrderDate]
	ON [sales].[Order] ([CustomerId] ASC, [OrderDate] ASC)
	INCLUDE ([Total]);
GO

CREATE TRIGGER [sales].[trg_Order_StatusAudit]
	ON [sales].[Order]
	AFTER UPDATE
AS
BEGIN
	SET NOCOUNT ON;

	INSERT INTO [audit].[OrderChange] ([OrderId], [OldStatusId], [NewStatusId])
	SELECT i.[OrderId], d.[StatusId], i.[StatusId]
	FROM inserted AS i
		INNER JOIN deleted AS d ON d.[OrderId] = i.[OrderId]
	WHERE d.[StatusId] <> i.[StatusId];
END
GO
