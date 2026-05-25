/* Additional database functions for openstreetmap-carto */

/* Access functions below adapted from https://github.com/imagico/osm-carto-alternative-colors/tree/591c861112b4e5d44badd108f4cd1409146bca0b/sql/roads.sql */

/* Simplified 'yes', 'destination', 'no', 'unrecognised', NULL scale for access restriction 
  'no' is returned if the rendering for highway category does not support 'restricted'.
  NULL is functionally equivalent to 'yes', but indicates the absence of a restriction 
  rather than a positive access = yes. 'unrecognised' corresponds to an uninterpretable 
  access restriction e.g. access=unknown or motorcar=occasionally */
CREATE OR REPLACE FUNCTION carto_int_access(accessvalue text, allow_restricted boolean)
	RETURNS text
	LANGUAGE SQL
	IMMUTABLE PARALLEL SAFE
AS $$
SELECT
	CASE
		WHEN accessvalue IN ('yes', 'designated', 'permissive') THEN 'yes'
		WHEN accessvalue IN ('destination',  'delivery', 'customers') THEN
			CASE WHEN allow_restricted = TRUE  THEN 'restricted' ELSE 'yes' END
		WHEN accessvalue IN ('no', 'permit', 'private', 'agricultural', 'forestry', 'agricultural;forestry') THEN 'no'
		WHEN accessvalue IS NULL THEN NULL
		ELSE 'unrecognised'
	END
$$;

/* Try to promote path to cycleway (if bicycle allowed), then bridleway (if horse)
   This duplicates existing behaviour where designated access is required */
CREATE OR REPLACE FUNCTION carto_path_type(bicycle text, horse text)
	RETURNS text
	LANGUAGE SQL
	IMMUTABLE PARALLEL SAFE
AS $$
SELECT
	CASE
		WHEN bicycle IN ('designated') THEN 'cycleway'
		WHEN horse IN ('designated') THEN 'bridleway'
		ELSE 'path'
	END
$$;

/* Return int_access value which will be used to determine access marking.
   Return values are documented above for carto_int_access function.

   Note that the code handling the promotion of highway=path assumes that
   promotion to cycleway or bridleway is based on the value of bicycle or
   horse respectively. A more general formulation would be, for example,
   WHEN 'cycleway' THEN carto_int_access(COALESCE(NULLIF(bicycle, 'unknown'), "access"), FALSE) */
CREATE OR REPLACE FUNCTION carto_highway_int_access(highway text, "access" text, foot text, bicycle text, horse text, motorcar text, motor_vehicle text, vehicle text)
  RETURNS text
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT
	CASE
		WHEN highway IN ('motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary', 'primary_link', 'secondary',
					 'secondary_link', 'tertiary', 'tertiary_link', 'residential', 'unclassified', 'living_street', 'service', 'road') THEN
			carto_int_access(
				COALESCE(
					NULLIF(motorcar, 'unknown'),
					NULLIF(motor_vehicle, 'unknown'),
					NULLIF(vehicle, 'unknown'),
					"access"), TRUE)
		WHEN highway = 'path' THEN
			CASE carto_path_type(bicycle, horse)
				WHEN 'cycleway' THEN carto_int_access(bicycle, FALSE)
				WHEN 'bridleway' THEN carto_int_access(horse, FALSE)
				ELSE carto_int_access(COALESCE(NULLIF(foot, 'unknown'), "access"), FALSE)
			END
		WHEN highway = 'pedestrian' THEN carto_int_access(COALESCE(NULLIF(foot, 'unknown'), "access"), TRUE)
		WHEN highway IN ('footway', 'steps') THEN carto_int_access(COALESCE(NULLIF(foot, 'unknown'), "access"), FALSE)
		WHEN highway = 'cycleway' THEN carto_int_access(COALESCE(NULLIF(bicycle, 'unknown'), "access"), FALSE)
		WHEN highway = 'bridleway' THEN carto_int_access(COALESCE(NULLIF(horse, 'unknown'), "access"), FALSE)
		ELSE carto_int_access("access", TRUE)
	END
$$;

/* Convert a Mapnik scale_denominator to an integer Web Mercator zoom level.
   Adapted from https://github.com/mapbox/postgis-vt-util/blob/master/src/Z.sql
   Intended usage:
     WHERE Z(!scale_denominator!) < 17 */
CREATE OR REPLACE FUNCTION Z(scale_denominator numeric)
  RETURNS integer
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
  RETURNS NULL ON NULL INPUT
AS $$
SELECT
	CASE
		WHEN scale_denominator <= 0 OR scale_denominator > 600000000 THEN NULL
		ELSE CAST(ROUND(LOG(2, 559082264.028 / scale_denominator)) AS integer)
	END
$$;

/* Area on the ground (in projected units, squared) covered by one rendered pixel
   at the given Mapnik scale_denominator. The 0.28 mm constant is the OGC
   standard pixel size; the *0.001 converts mm to m. Intended for use as a
   threshold for way_area comparisons, e.g.
     WHERE way_area > 100 * carto_pixel_area(!scale_denominator!) */
CREATE OR REPLACE FUNCTION carto_pixel_area(scale_denominator numeric)
  RETURNS double precision
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT POW(scale_denominator * 0.001 * 0.28, 2)::double precision
$$;

/* way_area expressed in rendered pixels at the given scale_denominator. */
CREATE OR REPLACE FUNCTION carto_way_pixels(way_area double precision, scale_denominator numeric)
  RETURNS double precision
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
-- Mapnik should not pass scale_denominator = 0 in practice; NULLIF preserves
-- the previous behavior and keeps query tests that substitute 0 from failing.
SELECT way_area / NULLIF(carto_pixel_area(scale_denominator), 0)
$$;

/* Buckets the OSM surface tag into 'paved' / 'unpaved' / NULL using the same
   value lists shared by every road, bridge, tunnel, and aeroway query. */
CREATE OR REPLACE FUNCTION carto_int_surface(surface text)
  RETURNS text
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT
	CASE
		WHEN surface IN ('unpaved', 'compacted', 'dirt', 'earth', 'fine_gravel', 'grass', 'grass_paver', 'gravel', 'ground',
		                 'mud', 'pebblestone', 'salt', 'sand', 'woodchips', 'clay', 'ice', 'snow') THEN 'unpaved'
		WHEN surface IN ('paved', 'asphalt', 'cobblestone', 'cobblestone:flattened', 'sett', 'concrete', 'concrete:lanes',
		                 'concrete:plates', 'paving_stones', 'metal', 'wood', 'unhewn_cobblestone') THEN 'paved'
	END
$$;

/* True iff the tunnel tag indicates the way passes through a structure that
   we should render as a tunnel. Returns false (not NULL) for tunnel IS NULL,
   so the result is a clean boolean for use in WHERE/NOT. */
CREATE OR REPLACE FUNCTION carto_is_tunnel(tunnel text)
  RETURNS boolean
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT COALESCE(tunnel IN ('yes', 'building_passage', 'avalanche_protector'), FALSE)
$$;

/* True iff the bridge tag indicates we should render the way as a bridge. */
CREATE OR REPLACE FUNCTION carto_is_bridge(bridge text)
  RETURNS boolean
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT COALESCE(bridge IN ('yes', 'boardwalk', 'cantilever', 'covered', 'low_water_crossing', 'movable', 'trestle', 'viaduct'), FALSE)
$$;

/* True iff the highway tag is one of the *_link variants. */
CREATE OR REPLACE FUNCTION carto_is_link(highway text)
  RETURNS boolean
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT COALESCE(highway IN ('motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link'), FALSE)
$$;

/* True iff the (boundary, protect_class) pair identifies a protected area
   recognised by our render. Excludes leisure=nature_reserve, which is checked
   alongside this in callers that need it. */
CREATE OR REPLACE FUNCTION carto_is_protected_area(boundary text, protect_class text)
  RETURNS boolean
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT COALESCE(
	boundary IN ('aboriginal_lands', 'national_park')
	  OR (boundary = 'protected_area' AND protect_class IN ('1','1a','1b','2','3','4','5','6')),
	FALSE)
$$;

/* 'yes'/'no' string for whether a waterway is intermittent or seasonal.
   Caller passes the extracted tag values (tags->'intermittent', tags->'seasonal').
   Note: the water-areas layer additionally checks tags->'basin' inline; that
   variation stays at the call site. */
CREATE OR REPLACE FUNCTION carto_water_intermittent(intermittent text, seasonal text)
  RETURNS text
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT
	CASE WHEN intermittent IN ('yes')
		OR seasonal IN ('yes', 'spring', 'summer', 'autumn', 'winter', 'wet_season', 'dry_season')
		THEN 'yes' ELSE 'no' END
$$;

/* 'yes'/'no' string for whether a waterway way runs through a tunnel/culvert.
   Treats waterway=canal + tunnel=flooded as a tunnel. */
CREATE OR REPLACE FUNCTION carto_waterway_int_tunnel(tunnel text, waterway text)
  RETURNS text
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT
	CASE WHEN tunnel IN ('yes', 'culvert')
		OR (waterway = 'canal' AND tunnel = 'flooded')
		THEN 'yes' ELSE 'no' END
$$;

/* Trivially folds a tag value into a 'yes'/'no' string: 'yes' iff the value is
   literally 'yes', otherwise 'no'. Used for tag values where we only care
   about the affirmative case (e.g. tags->'railway:preserved'). */
CREATE OR REPLACE FUNCTION carto_yes_no(value text)
  RETURNS text
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT CASE WHEN value = 'yes' THEN 'yes' ELSE 'no' END
$$;

/* Synthetic kind for a railway way: the railway tag, with two replacements
   for spur/siding/yard service ways on rail and tram. Callers prepend
   'railway_' themselves when they need the full feature name. */
CREATE OR REPLACE FUNCTION carto_railway_kind(railway text, service text)
  RETURNS text
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT
	CASE
		WHEN railway = 'rail' AND service IN ('spur', 'siding', 'yard') THEN 'INT-spur-siding-yard'
		WHEN railway = 'tram' AND service IN ('spur', 'siding', 'yard') THEN 'tram-service'
		ELSE railway
	END
$$;

/* INT-minor / INT-normal classification for highway service ways. The leisure
   argument is checked for 'slipway' (a slip ramp is treated as a minor service
   way). Pass NULL for leisure when the caller does not have it. */
CREATE OR REPLACE FUNCTION carto_service_class(service text, leisure text)
  RETURNS text
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT
	CASE
		WHEN service IN ('parking_aisle', 'drive-through', 'driveway') OR leisure = 'slipway' THEN 'INT-minor'
		ELSE 'INT-normal'
	END
$$;

/* 'restricted' / 'yes' classification used by POI layers (distinct from the
   highway-oriented carto_int_access above; restricted POIs cover a wider set
   of access tag values). */
CREATE OR REPLACE FUNCTION carto_poi_int_access(access_value text)
  RETURNS text
  LANGUAGE SQL
  IMMUTABLE PARALLEL SAFE
AS $$
SELECT CASE WHEN access_value IN ('private', 'no', 'customers', 'permit', 'delivery') THEN 'restricted' ELSE 'yes' END
$$;
