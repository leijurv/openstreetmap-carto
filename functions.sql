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

/* Issue #951 -- render-time aggregation of split road geometries so that one
   label/shield is placed per logical road instead of per OSM way, while keeping
   the merged geometry identical across (meta)tile boundaries.

   The aggregation grid is the metatile grid offset by half a metatile, so every
   metatile overlaps exactly four cells; a feature is binned by the centre of its
   bounding box. This function returns which of those four cells (0..3) a feature
   belongs to, or NULL if the feature must NOT be merged. A feature is mergeable
   only when its whole bounding box fits inside the union of the (up to four)
   metatiles that own its cell, shrunk by the render buffer plus a small margin.
   That guarantees the merged geometry never reaches a metatile which does not
   share the cell -- so every metatile that can render it computes the identical
   merge, and there are no tile-edge inconsistencies. Features failing the test
   (too large, or centre outside the four cells) get NULL and pass through whole.

   The margin (+8 projection units, ~a few float4 ULPs of the Web Mercator
   extent) absorbs the fact that Mapnik's `way && !bbox!` feature selection uses
   single-precision bounding boxes: without it a merged feature could be picked
   up, unmerged, by a neighbour a metre or two outside the contracted union.

   Pass the four bbox extents pre-extracted (ST_XMin(way) etc., once each) so the
   expression inlines; ub must be the !unbuffered_bbox! literal (constant) and
   buf the buffer width, e.g. ST_XMax(!bbox!) - ST_XMax(!unbuffered_bbox!). */
CREATE OR REPLACE FUNCTION carto_label_merge_cell(
		xmin double precision, xmax double precision,
		ymin double precision, ymax double precision,
		ub geometry, buf double precision)
	RETURNS integer
	LANGUAGE SQL
	IMMUTABLE PARALLEL SAFE
AS $$
	SELECT CASE
		WHEN round(((xmin + xmax) / 2 - ST_XMin(ub)) / (ST_XMax(ub) - ST_XMin(ub)))::int IN (0, 1)
		 AND round(((ymin + ymax) / 2 - ST_YMin(ub)) / (ST_YMax(ub) - ST_YMin(ub)))::int IN (0, 1)
		 AND xmin >= ST_XMin(ub) + (round(((xmin + xmax) / 2 - ST_XMin(ub)) / (ST_XMax(ub) - ST_XMin(ub))) - 1) * (ST_XMax(ub) - ST_XMin(ub)) + (buf + 8)
		 AND xmax <= ST_XMin(ub) + (round(((xmin + xmax) / 2 - ST_XMin(ub)) / (ST_XMax(ub) - ST_XMin(ub))) + 1) * (ST_XMax(ub) - ST_XMin(ub)) - (buf + 8)
		 AND ymin >= ST_YMin(ub) + (round(((ymin + ymax) / 2 - ST_YMin(ub)) / (ST_YMax(ub) - ST_YMin(ub))) - 1) * (ST_YMax(ub) - ST_YMin(ub)) + (buf + 8)
		 AND ymax <= ST_YMin(ub) + (round(((ymin + ymax) / 2 - ST_YMin(ub)) / (ST_YMax(ub) - ST_YMin(ub))) + 1) * (ST_YMax(ub) - ST_YMin(ub)) - (buf + 8)
		THEN round(((xmin + xmax) / 2 - ST_XMin(ub)) / (ST_XMax(ub) - ST_XMin(ub)))::int * 2
		   + round(((ymin + ymax) / 2 - ST_YMin(ub)) / (ST_YMax(ub) - ST_YMin(ub)))::int
	END
$$;
