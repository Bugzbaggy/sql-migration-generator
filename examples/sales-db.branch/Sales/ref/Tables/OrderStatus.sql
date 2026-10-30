CREATE TABLE [ref].[OrderStatus]
(
	[StatusId] TINYINT NOT NULL,
	[Name] VARCHAR (30) NOT NULL,
	CONSTRAINT [PK_OrderStatus] PRIMARY KEY CLUSTERED ([StatusId] ASC),
	CONSTRAINT [UQ_OrderStatus_Name] UNIQUE NONCLUSTERED ([Name] ASC)
);
GO

GRANT SELECT
	ON OBJECT::[ref].[OrderStatus] TO [role_reporting]
	AS [dbo];
GO
