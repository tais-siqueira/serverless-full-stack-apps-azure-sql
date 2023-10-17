-- Monitor the "Education Hill - Crossroads - Eastgate" route
delete from dbo.[MonitoredRoutes];
insert into dbo.[MonitoredRoutes] (RouteId) values (100113);
go

-- Create a geofence
delete from dbo.[GeoFences];
insert into dbo.[GeoFences] 
	([Name], [GeoFence]) 
values
	('Crossroads', 0xE6100000010407000000B4A78EA822CF4740E8D7539530895EC03837D51CEACE4740E80BFBE630895EC0ECD7DF53EACE4740E81B2C50F0885EC020389F0D03CF4740E99BD2A1F0885EC00CB8BEB203CF4740E9DB04FC23895EC068C132B920CF4740E9DB04FC23895EC0B4A78EA822CF4740E8D7539530895EC001000000020000000001000000FFFFFFFF0000000003);
go

DROP TABLE IF EXISTS #t;
DROP TABLE IF EXISTS #g;
DROP TABLE IF EXISTS #r;

DECLARE @payload NVARCHAR(max) = N'[{
		"DirectionId": 1,
		"RouteId": 100001,
		"VehicleId": 1,
		"Position": {
			"Latitude": 47.61705102765316,
			"Longitude": -122.14291865504012 
		},
		"TimestampUTC": "20201031"
	},{
        "DirectionId": 1,
		"RouteId": 100531,
		"VehicleId": 2,
		"Position": {
			"Latitude": 47.61346156765316,
			"Longitude": -122.14291784492805
		},
		"TimestampUTC": "20201031"
}]';

SELECT
	[DirectionId], 
	[RouteId], 
	[VehicleId], 
	GEOGRAPHY::Point([Latitude], [Longitude], 4326) AS [Location], 
	[TimestampUTC]
INTO #t
FROM
	openjson(@payload) WITH (
		[DirectionId] INT,
		[RouteId] INT,
		[VehicleId] INT,
		[Latitude] DECIMAL(10,6) '$.Position.Latitude',
		[Longitude] DECIMAL(10,6) '$.Position.Longitude',
		[TimestampUTC] DATETIME2(7)
	);


select * from #t;

SELECT [VehicleId], [Location].ToString() AS Location FROM #t;

declare @bus1 geography;
declare @bus2 geography;
select @bus1 = [Location] from #t where VehicleId = 1;
select @bus2 = [Location] from #t where VehicleId = 2;
select @bus1.STDistance(@bus2) as DistanceInMeters;

SELECT * INTO #g 
FROM (VALUES(
        CAST('Overlake Stop' AS NVARCHAR(100)),
        GEOGRAPHY::STGeomFromText('POLYGON ((-122.14359028995352 47.618245191245848, -122.14360975757847 47.616519550427654, -122.13966755206604 47.616526111887509, -122.13968701903617 47.617280676597375, -122.142821316476 47.617300360798339, -122.142821316476 47.618186139853435, -122.14359028995352 47.618245191245848))',4326)
    ))
    AS s ([BusStop], [GeoFence])
SELECT * FROM #g

SELECT
    t.DirectionId,
    t.RouteId,
    t.VehicleId,
    GEOGRAPHY::STGeomCollFromText('GEOMETRYCOLLECTION(' + t.[Location].ToString() + ', ' + g.[GeoFence].ToString() +')',4326).ToString() as [WKT],
    t.[Location].STWithin(g.[GeoFence]) as InGeoFence
INTO #r 
FROM #t AS t 
CROSS JOIN #g AS g 
WHERE g.[BusStop] = 'Overlake Stop';

SELECT * FROM #r;

create schema [web] AUTHORIZATION [dbo];
go

DROP TABLE IF EXISTS #t;
DROP TABLE IF EXISTS #g;
DROP TABLE IF EXISTS #r;

/*
	Add received Bus geolocation data and check if buses are
	inside any defined GeoFence. JSON must be like:

	{
		"DirectionId": 1,
		"RouteId": 100001,
		"VehicleId": 2,
		"Position": {
			"Latitude": 47.61705102765316,
			"Longitude": -122.14291865504012 
		},
		"TimestampUTC": "20201031"
	}
}
*/
create or alter procedure [web].[AddBusData]
@payload nvarchar(max) 
as
begin	
	set nocount on
	set xact_abort on
	set tran isolation level serializable

	begin tran
if (isjson(@payload) != 1) begin;
		throw 50000, 'Payload is not a valid JSON document', 16;
	end;

	declare @ids as table (id int);

	-- insert bus data
	insert into dbo.[BusData] 
		([DirectionId], [RouteId], [VehicleId], [Location], [TimestampUTC])
	output
		inserted.Id into @ids
	select
		[DirectionId], 
		[RouteId], 
		[VehicleId], 
		geography::Point([Latitude], [Longitude], 4326) as [Location], 
		[TimestampUTC]
	from
		openjson(@payload) with (
			[DirectionId] int,
			[RouteId] int,
			[VehicleId] int,
			[Latitude] decimal(10,6) '$.Position.Latitude',
			[Longitude] decimal(10,6) '$.Position.Longitude',
			[TimestampUTC] datetime2(7)
		);
		
	-- Get details of inserted data
	select * into #t from dbo.[BusData] bd where bd.id in (select i.id from @ids i);

	-- Find geofences in which the vehicle is in
	select 
		t.Id as BusDataId,
		t.[VehicleId],
		t.[DirectionId],
		t.[TimestampUTC],
		t.[RouteId],		
		g.Id as GeoFenceId
	into
		#g
	from 
		dbo.GeoFences g 
	right join
		#t t on g.GeoFence.STContains(t.[Location]) = 1;

	-- Calculate status
	select
		c.BusDataId,
		coalesce(a.[GeoFenceId], c.[GeoFenceId]) as GeoFenceId,
		coalesce(a.[DirectionId], c.[DirectionId]) as DirectionId,
		coalesce(a.[VehicleId], c.[VehicleId]) as VehicleId,
		c.[RouteId],
		c.[TimestampUTC],
		case 
			when a.GeoFenceId is null and c.GeoFenceId is not null then 'Enter'
			when a.GeoFenceId is not null and c.GeoFenceId is null then 'Exit'		
		end as [Status]
	into
		#s 
	from
		#g c
	full outer join
		dbo.GeoFencesActive a on c.DirectionId = a.DirectionId and c.VehicleId = a.VehicleId;
	
	-- Delete exited geofences
	delete 
		a
	from
		dbo.GeoFencesActive a
	inner join
		#s s on a.VehicleId = s.VehicleId and s.DirectionId = a.DirectionId and s.[Status] = 'Exit';

	-- Insert entered geofences
	insert into dbo.GeoFencesActive 
		([GeoFenceId], [DirectionId], [VehicleId])
	select
		[GeoFenceId], [DirectionId], [VehicleId]
	from
		#s s
	where 
		s.[Status] = 'Enter';

	-- Insert Log
	insert into dbo.GeoFenceLog 
		(GeoFenceId, BusDataId, [RouteId], [VehicleId], [TimestampUTC], [Status])
	select
		GeoFenceId, BusDataId, [RouteId], [VehicleId], [TimestampUTC], isnull([Status], 'In')
	from
		#s s
	where
		s.[GeoFenceId] is not null
	and
		s.[BusDataId] is not null

	-- Return Entered or Exited geofences
	select
	((
		select
			s.[BusDataId],  
			s.[VehicleId],
			s.[DirectionId],  
			s.[RouteId], 
			r.[ShortName] as RouteName,
			s.[GeoFenceId], 
			gf.[Name] as GeoFence,
			s.[Status] as GeoFenceStatus,
			s.[TimestampUTC]
		from
			#s s
		inner join
			dbo.[GeoFences] gf on s.[GeoFenceId] = gf.[Id]
		inner join
			dbo.[Routes] r on s.[RouteId] = r.[Id]
		where
			s.[Status] is not null and s.[GeoFenceId] is not null
		for 
			json path
	)) as ActivatedGeoFences;

	commit
end

/*
	Return the Routes (and thus the buses) to monitor
*/
create or alter procedure [web].[GetMonitoredRoutes]
as
begin
	select 
	((	
		select RouteId from dbo.[MonitoredRoutes] for json auto
	)) as MonitoredRoutes
end
GO

/*
	Return last geospatial data for bus closest to the GeoFence
*/
create or alter procedure [web].[GetMonitoredBusData]
@routeId int,
@geofenceId int
as
begin
	with cte as
	(
		-- Get the latest location of all the buses in the given route
		select top (1) with ties 
			*  
		from 
			dbo.[BusData] 
		where
			[RouteId] = @routeId
		order by 
			[ReceivedAtUTC] desc
	),
	cte2 as
	(
		-- Get the closest to the GeoFence
		select top (1)
			c.[VehicleId],
			gf.[GeoFence],
			c.[Location].STDistance(gf.[GeoFence]) as d
			from
			[cte] c
		cross join
			dbo.[GeoFences] gf
		where
			gf.[Id] = @geofenceId
		order by
			d 
	), cte3 as
	(
	-- Take the last 50 points 
	select top (50)
		[bd].[VehicleId],
		[bd].[DirectionId],
		[bd].[Location] as l,
		[bd].[Location].STDistance([GeoFence]) as d
	from
		dbo.[BusData] bd
	inner join
		cte2 on [cte2].[VehicleId] = [bd].[VehicleId]
	order by 
		id desc
	)
	-- Return only the points that are withing 5 Km
	select 
	((
		select
			geography::UnionAggregate(l).ToString() as [busData],
			(select [GeoFence].ToString() from dbo.[GeoFences] where Id = @geofenceId) as [geoFence]
		from
			cte3
		where
			d < 5000
		for json auto, include_null_values, without_array_wrapper
	)) as locationData
end
GO

SELECT * FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_SCHEMA = 'web'