/*
	Full documentation on "Accessing data in a CSV file referencing an Azure blob storage location" here:
	https://docs.microsoft.com/en-us/sql/relational-databases/import-export/examples-of-bulk-access-to-data-in-azure-blob-storage?view=sql-server-ver15
*/

CREATE TABLE [dbo].[Routes]
(
	[Id] [int] NOT NULL,
	[AgencyId] [varchar](100) NULL,
	[ShortName] [varchar](100) NULL,
	[Description] [varchar](1000) NULL,
	[Type] [int] NULL
)
GO
ALTER TABLE [dbo].[Routes] ADD PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)
GO

CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'mySuperStr0n9P@assw0rd!'

create database scoped credential AzureBlobCredentials
with identity = 'SHARED ACCESS SIGNATURE',
secret = 'sp=r&st=2021-03-12T00:47:24Z&se=2025-03-11T07:47:24Z&spr=https&sv=2020-02-10&sr=c&sig=BmuxFevKhWgbvo%2Bj8TlLYObjbB7gbvWzQaAgvGcg50c%3D' -- Omit any leading question mark
go

create external data source RouteData
with (
	type = blob_storage,
	location = 'https://azuresqlworkshopsa.blob.core.windows.net/bus',
	credential = AzureBlobCredentials
)

delete from dbo.[Routes];
go

insert into dbo.[Routes]
	([Id], [AgencyId], [ShortName], [Description], [Type])
select 
	[Id], [AgencyId], [ShortName], [Description], [Type]
from 
openrowset
	( 
		bulk 'routes.txt', 
		data_source = 'RouteData', 
		formatfile = 'routes.fmt', 
		formatfile_data_source = 'RouteData', 
		firstrow=2,
		format='csv'
	) t;
go

select * from dbo.[Routes] where [Description] like '%Education Hill%'
go

select * from sys.[database_credentials]
select * from sys.[external_data_sources]
go


CREATE TABLE [dbo].[MonitoredRoutes]
(
	[RouteId] [int] NOT NULL
)
GO
ALTER TABLE [dbo].[MonitoredRoutes] ADD PRIMARY KEY CLUSTERED 
(
	[RouteId] ASC
)
GO
ALTER TABLE [dbo].[MonitoredRoutes] 
ADD CONSTRAINT [FK__MonitoredRoutes__Router] 
FOREIGN KEY ([RouteId]) REFERENCES [dbo].[Routes] ([Id])
GO

-- Monitor the "Education Hill - Crossroads - Eastgate" route
INSERT INTO dbo.[MonitoredRoutes] (RouteId) VALUES (100113);

CREATE SEQUENCE [dbo].[global]
    AS INT
    START WITH 1
    INCREMENT BY 1
GO
CREATE TABLE [dbo].[GeoFences](
	[Id] [int] NOT NULL,
	[Name] [nvarchar](100) NOT NULL,
	[GeoFence] [geography] NOT NULL
) 
GO
ALTER TABLE [dbo].[GeoFences] ADD PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)
GO
ALTER TABLE [dbo].[GeoFences] ADD DEFAULT (NEXT VALUE FOR [dbo].[global]) FOR [Id]
GO
CREATE SPATIAL INDEX [ixsp] ON [dbo].[GeoFences]
(
	[GeoFence]
) USING GEOGRAPHY_AUTO_GRID 
GO

-- Create a GeoFence
INSERT INTO dbo.[GeoFences] 
	([Name], [GeoFence]) 
VALUES
	('Crossroads', 0xE6100000010407000000B4A78EA822CF4740E8D7539530895EC03837D51CEACE4740E80BFBE630895EC0ECD7DF53EACE4740E81B2C50F0885EC020389F0D03CF4740E99BD2A1F0885EC00CB8BEB203CF4740E9DB04FC23895EC068C132B920CF4740E9DB04FC23895EC0B4A78EA822CF4740E8D7539530895EC001000000020000000001000000FFFFFFFF0000000003);
GO

CREATE TABLE [dbo].[GeoFencesActive] 
(
	[Id] [int] IDENTITY(1,1) NOT NULL PRIMARY KEY CLUSTERED,
	[VehicleId] [int] NOT NULL,
	[DirectionId] [int] NOT NULL,
	[GeoFenceId] [int] NOT NULL,
	[SysStartTime] [datetime2](7) GENERATED ALWAYS AS ROW START NOT NULL,
	[SysEndTime] [datetime2](7) GENERATED ALWAYS AS ROW END NOT NULL,
	PERIOD FOR SYSTEM_TIME ([SysStartTime], [SysEndTime])
)
WITH ( SYSTEM_VERSIONING = ON ( HISTORY_TABLE = [dbo].[GeoFencesActiveHistory] ) )
GO

CREATE TABLE [dbo].[BusData](
	[Id] [int] IDENTITY(1,1) NOT NULL,
	[DirectionId] [int] NOT NULL,
	[RouteId] [int] NOT NULL,
	[VehicleId] [int] NOT NULL,
	[Location] [geography] NOT NULL,
	[TimestampUTC] [datetime2](7) NOT NULL,
	[ReceivedAtUTC] [datetime2](7) NOT NULL
)
GO
ALTER TABLE [dbo].[BusData] ADD DEFAULT (SYSUTCDATETIME()) FOR [ReceivedAtUTC]
GO
ALTER TABLE [dbo].[BusData] ADD PRIMARY KEY CLUSTERED 
(
	[Id] ASC
) 
GO
CREATE NONCLUSTERED INDEX [ix1] ON [dbo].[BusData]
(
	[ReceivedAtUTC] DESC
) 
GO
CREATE SPATIAL INDEX [ixsp] ON [dbo].[BusData]
(
	[Location]
) USING GEOGRAPHY_AUTO_GRID 
GO

SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA = 'dbo'