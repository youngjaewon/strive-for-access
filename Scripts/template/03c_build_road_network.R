# =============================================================================
# 03c_build_road_network.R
# -----------------------------------------------------------------------------
# Strive for Access (SFA) - Park Access Point Dataset pipeline
#
# Purpose:
#   Build the vehicle accessible road network for the whole state in one run,
#   and extract statewide OSM parking as a point layer in the same pass. Both
#   come from the Geofabrik North Carolina extract via osmextract. Roads are
#   filtered with an adapted version of the ORS driving-car tag filtering
#   profile. The outputs are consumed by 03d_estimate_missing_access_points.R,
#   which clips both per county, with no Overpass calls at run time.
#
# Base rule: ORS driving-car tag filtering profile
#   https://giscience.github.io/openrouteservice/technical-details/tag-filtering#driving-car
#   Key modifications from the ORS defaults are documented inline below and are
#   unchanged from the previous per county version of this script.
#
# Why statewide instead of per county
#   The previous version queried Overpass once per county. Covering the state
#   that way means about 100 rate limited API calls, each hitting a different
#   OSM snapshot. One Geofabrik extract downloads once, filters once, and gives
#   every county the same data vintage. The .pbf download is roughly 300 MB and
#   is cached by osmextract, so reruns skip the download.
#
# Output
#   roads/nc_roads_ors.gpkg (statewide road lines, EPSG 4326)
#   roads/nc_parking.gpkg   (statewide parking points, EPSG 4326; polygon
#                            parking lots are stored as centroids)
# =============================================================================

# --- Packages ----------------------------------------------------------------

library(osmextract)
library(sf)
library(tidyverse)


# =============================================================================
# CONFIG (check paths, then run)
# =============================================================================

root <- "/Users/ywon3/Library/CloudStorage/Dropbox/03_Strive for Access/Data"

output_path  <- file.path(root, "roads", "nc_roads_ors.gpkg")
parking_path <- file.path(root, "roads", "nc_parking.gpkg")

# Where osmextract caches the Geofabrik .pbf and the translated .gpkg.
# Keeping it under the project makes the data vintage easy to track.
osm_cache_dir <- file.path(root, "roads", "osm_cache")


# =============================================================================
# PART 1: ORS RULE DEFINITIONS (unchanged from the per county version)
# =============================================================================

# ORS original:
#   wayTypesWithDefaultSpeed = [motorway, motorway_link, motorroad, trunk,
#     trunk_link, primary, primary_link, secondary, secondary_link, tertiary,
#     tertiary_link, unclassified, residential, living_street, service,
#     road, track]
#
# MODIFICATION: "motorway" removed. Park entrances rarely connect directly
# to controlled-access highways, so motorway segments are not relevant for
# estimating access points. "motorway_link" is retained so that interchange
# ramp connections to lower-class roads are still captured.
road_types <- c(
  "motorway_link", "motorroad", "trunk", "trunk_link",
  "primary", "primary_link", "secondary", "secondary_link",
  "tertiary", "tertiary_link", "unclassified", "residential",
  "living_street", "service", "road", "track"
)

# ORS original:
#   intendedValues = [yes, permissive, destination]
intended <- c("yes", "permissive", "destination")

# ORS original:
#   restrictedValues = [private, agricultural, forestry, no, restricted,
#                       delivery, military, emergency]
#
# In ORS, firstValue = restrictedValues is treated as CONDITIONAL (not a
# hard reject). We treat it as a hard reject for park access purposes, with
# one exception: "forestry" is intentionally excluded from our restricted
# list. In NC, state forests and game lands often tag their access roads as
# access=forestry, and these may be the only vehicle route to a park
# entrance. Hard-rejecting forestry would produce false negatives, with
# parks that are actually reachable by car appearing inaccessible.
restricted <- c(
  "private", "agricultural", "no",
  "restricted", "delivery", "military", "emergency"
)

# ORS original:
#   restrictions = [motorcar, motor_vehicle, vehicle, access]
#   firstValue   = value of the first encountered key from restrictions
#
# We replicate the same priority order. If motorcar is tagged, it takes
# precedence over motor_vehicle, which takes precedence over vehicle, etc.
get_first <- function(x) {
  coalesce(x$motorcar, x$motor_vehicle, x$vehicle, x$access)
}

# OSM keys the filter reads. osmextract only materializes tags it is told
# about, so every key used in PART 3 must be listed here.
filter_tags <- c(
  "motorcar", "motor_vehicle", "vehicle", "access",
  "ford", "tracktype", "impassable", "smoothness", "status", "maxwidth"
)


# =============================================================================
# PART 2: DOWNLOAD AND READ THE STATEWIDE EXTRACT
# =============================================================================

# ORS original rule 1-3: highway != * AND route = [shuttle_train, ferry]
# is conditionally accepted. The SQL below only reads features with a highway
# tag in road_types, so ferry/shuttle routes (tagged route=ferry without a
# highway key) are excluded by design. Park access should be road-based.
#
# The highway filter runs inside the GDAL translation, so segments of other
# types never reach R. This is the statewide equivalent of the old
# add_osm_feature("highway", road_types) call.

dir.create(osm_cache_dir, recursive = TRUE, showWarnings = FALSE)

message("Downloading and reading the Geofabrik North Carolina extract...")

roads <- oe_get(
  "us/north-carolina",
  provider         = "geofabrik",
  layer            = "lines",
  extra_tags       = filter_tags,
  download_directory = osm_cache_dir,
  force_vectortranslate = TRUE,
  query = paste0(
    "SELECT osm_id, name, highway, ",
    paste(filter_tags, collapse = ", "),
    ", geometry FROM lines WHERE highway IN ('",
    paste(road_types, collapse = "','"),
    "')"
  ),
  quiet = FALSE
)

stopifnot(inherits(roads, "sf"))

message(nrow(roads), " road segments read.")


# =============================================================================
# PART 3: APPLY ORS FILTERING RULES (unchanged from the per county version)
# =============================================================================

# Ensure optional OSM columns exist before filtering. Pre-filling with
# NA_character_ avoids errors in downstream parsing.
optional_cols <- c("impassable", "smoothness", "status",
                   "tracktype", "ford", "maxwidth")
for (col in optional_cols) {
  if (!col %in% names(roads)) roads[[col]] <- NA_character_
}

roads_filtered <- roads |>
  mutate(
    access_val = get_first(roads),
    track_num  = readr::parse_number(tracktype),
    width_num  = readr::parse_number(maxwidth)
  ) |>
  filter(
    # ORS rule: highway != wayTypesWithDefaultSpeed -> Reject
    # Already enforced in the read query; kept as a safety net.
    highway %in% road_types,
    
    # ORS rule: highway = ford OR ford = * -> Conditional
    # MODIFICATION: hard reject. Ford crossings are seasonally unreliable
    # and cannot be assumed passable for general park visitors.
    highway != "ford",
    is.na(ford),
    
    # ORS rule: highway = track AND tracktype > grade3 -> Reject
    # NO MODIFICATION, same threshold as ORS. grade3 tracks (hard or
    # mixed surface) are drivable by regular passenger vehicles and may
    # be the only access route to rural parks.
    !(highway == "track" & !is.na(track_num) & track_num > 3),
    
    # ORS rule: impassable = yes OR [status, smoothness] = impassable -> Reject
    # NO MODIFICATION.
    is.na(impassable) | impassable != "yes",
    is.na(smoothness) | smoothness != "impassable",
    is.na(status)     | status     != "impassable",
    
    # ORS rule: maxwidth < 2 -> Reject
    # NO MODIFICATION. Roads narrower than 2 meters cannot accommodate
    # standard passenger vehicles.
    is.na(width_num) | width_num >= 2,
    
    # ORS rule: firstValue = restrictedValues -> Conditional
    # MODIFICATION: hard reject (except forestry, see note above).
    is.na(access_val) | !access_val %in% restricted,
    
    # ORS rule: firstValue = intendedValues -> Accept
    # Roads explicitly tagged as accessible are accepted. Untagged roads
    # (access_val = NA) are also accepted (ORS default behavior).
    is.na(access_val) | access_val %in% intended
  )

message(nrow(roads_filtered), " road segments retained after filtering.")

cat("\nRetained segments by highway type:\n")
print(roads_filtered |> st_drop_geometry() |> as_tibble() |> count(highway, sort = TRUE), n = Inf)


# =============================================================================
# PART 4: WRITE OUTPUT
# =============================================================================

# The Geofabrik extract is cut along the state boundary with a small buffer,
# so a thin margin of out of state roads remains. They are kept on purpose:
# parks on the state line may be reached from roads across the border, and
# 03d clips to its county of interest anyway.

roads_out <- roads_filtered |>
  select(osm_id, name, highway, geometry)

if (!dir.exists(dirname(output_path))) dir.create(dirname(output_path), recursive = TRUE)

st_write(roads_out, output_path, layer = "roads", delete_dsn = TRUE, quiet = TRUE)

message("Statewide filtered road network written: ", output_path)
message(nrow(roads_out), " segments, single file replacing the per county outputs.")


# =============================================================================
# PART 5: EXTRACT STATEWIDE OSM PARKING
# =============================================================================
# amenity=parking lives on OSM nodes (the points layer) and on closed ways and
# relations (the multipolygons layer). Both are pulled from the same cached
# .pbf, polygons are collapsed to centroids, and everything is written as one
# statewide point layer. 03d reads the county window from it with wkt_filter,
# which replaces the per county Overpass call that kept timing out.

message("Extracting parking points from the cached extract...")

parking_nodes <- oe_get(
  "us/north-carolina",
  provider           = "geofabrik",
  layer              = "points",
  extra_tags         = "amenity",
  download_directory = osm_cache_dir,
  force_vectortranslate = TRUE,
  query = "SELECT osm_id, name, amenity, geometry FROM points WHERE amenity = 'parking'",
  quiet = FALSE
)

message("Extracting parking polygons from the cached extract...")

# In the multipolygons layer, closed ways carry their id in osm_way_id and
# have osm_id = NA (osm_id is only set for relations). Both are read and
# merged into one identifier; otherwise distinct() collapses every way-based
# parking lot into a single NA row.
parking_polys <- oe_get(
  "us/north-carolina",
  provider           = "geofabrik",
  layer              = "multipolygons",
  extra_tags         = "amenity",
  download_directory = osm_cache_dir,
  force_vectortranslate = TRUE,
  query = "SELECT osm_id, osm_way_id, name, amenity, geometry FROM multipolygons WHERE amenity = 'parking'",
  quiet = FALSE
)

stopifnot(inherits(parking_nodes, "sf"), inherits(parking_polys, "sf"))

# Centroids are computed in the projected CRS, then everything returns to 4326.
parking_centroids <- parking_polys |>
  st_make_valid() |>
  filter(!st_is_empty(geometry)) |>
  st_transform(32119) |>
  st_centroid() |>
  st_transform(4326) |>
  transmute(
    osm_id = coalesce(
      if_else(!is.na(osm_id), paste0("rel_", osm_id), NA_character_),
      paste0("way_", osm_way_id)
    ),
    name,
    parking_geom = "polygon_centroid"
  )

parking_points <- parking_nodes |>
  filter(!st_is_empty(geometry)) |>
  transmute(osm_id = paste0("node_", osm_id), name, parking_geom = "point")

parking_all <- bind_rows(parking_centroids, parking_points) |>
  filter(!is.na(osm_id)) |>
  distinct(osm_id, .keep_all = TRUE)

st_write(parking_all, parking_path, layer = "parking", delete_dsn = TRUE, quiet = TRUE)

message("Statewide parking points written: ", parking_path)
message(nrow(parking_all), " parking locations (",
        sum(parking_all$parking_geom == "polygon_centroid"), " polygon centroids, ",
        sum(parking_all$parking_geom == "point"), " points).")