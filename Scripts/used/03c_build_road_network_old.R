# =============================================================================
# 03c_build_road_network.R
# -----------------------------------------------------------------------------
# Strive for Access (SFA) - Park Access Point Dataset pipeline
#
# Purpose:
#   Download OSM roads for one county and filter them to vehicle-accessible
#   segments using an adapted version of the ORS driving-car tag filtering
#   profile. The filtered road network is cached per county and consumed by
#   03d_generate_missing_access_points.R (boundary intersection and nearest
#   road snapping).
#
# Base rule: ORS driving-car tag filtering profile
#   https://giscience.github.io/openrouteservice/technical-details/tag-filtering#driving-car
#
# Key modifications from the ORS defaults are documented inline below.
# The ORS rules combine multiple OSM key-value pairs (beyond just the
# highway tag) to determine whether a road segment is vehicle-accessible.
#
# Usage:
#   Set county_name in the CONFIG section, then run the whole script.
#   Output: roads/{county_slug}_roads_ors.geojson
# =============================================================================

# --- Packages ----------------------------------------------------------------

library(osmdata)
library(sf)
library(tidyverse)
library(tigris)

# set_overpass_url("https://overpass.kumi.systems/api/interpreter")


# =============================================================================
# CONFIG (set the county, then run)
# =============================================================================

# Paths
root <- "/Volumes/Strive4Access/Data"

# County to process. Use the official TIGER/Line county name.
# This is more stable than passing a place name string to opq() directly,
# which relies on Nominatim geocoding and returns a rectangular bounding box
# that can spill into adjacent counties, especially problematic for
# irregularly shaped or coastal counties.
county_name <- "Carteret"
state_name  <- "NC"

# Output: root/roads/{county_slug}_roads_ors.geojson
county_slug <- tolower(gsub(" ", "_", county_name))
output_path <- file.path(root, "roads",
                         paste0(county_slug, "_roads_ors.geojson"))

# Overpass query timeout (seconds)
overpass_timeout <- 180


# =============================================================================
# PART 1: COUNTY BOUNDARY & BBOX
# =============================================================================

county_sf <- counties(state = state_name, cb = TRUE, progress_bar = FALSE) %>%
  filter(NAME == county_name) %>%
  st_transform(4326)

stopifnot(nrow(county_sf) == 1)

bbox <- st_bbox(county_sf)


# =============================================================================
# PART 2: ORS RULE DEFINITIONS
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


# =============================================================================
# PART 3: DOWNLOAD OSM ROADS
# =============================================================================

# ORS original rule 1-3: highway != * AND route = [shuttle_train, ferry]
# is conditionally accepted. Our osmdata query only fetches features with a
# highway tag, so ferry/shuttle routes (tagged as route=ferry without a
# highway key) are excluded by design. Park access should be road-based.
#
# bbox is derived from the TIGER/Line county boundary. Because Overpass
# always queries a rectangle, roads just outside the county boundary may
# be included; these are clipped after filtering via st_intersection().

message("Downloading OSM roads for ", county_name, " County...")

roads <- opq(bbox = bbox, timeout = overpass_timeout) %>%
  add_osm_feature("highway", road_types) %>%
  osmdata_sf() %>%
  pluck("osm_lines")

message(nrow(roads), " road segments downloaded.")


# =============================================================================
# PART 4: APPLY ORS FILTERING RULES
# =============================================================================

# Ensure optional OSM columns exist before filtering. Not all columns are
# returned by Overpass; e.g., maxwidth is rarely tagged. Pre-filling with
# NA_character_ avoids errors in downstream parsing.
optional_cols <- c("impassable", "smoothness", "status",
                   "tracktype", "ford", "maxwidth")
for (col in optional_cols) {
  if (!col %in% names(roads)) roads[[col]] <- NA_character_
}

roads_filtered <- roads %>%
  mutate(
    access_val = get_first(.),
    track_num  = readr::parse_number(tracktype),
    width_num  = readr::parse_number(maxwidth)
  ) %>%
  filter(
    # ORS rule: highway != wayTypesWithDefaultSpeed -> Reject
    # Ensures only recognized drivable road types are kept.
    highway %in% road_types,

    # ORS rule: highway = ford OR ford = * -> Conditional
    # MODIFICATION: hard reject. Ford crossings are seasonally unreliable
    # and cannot be assumed passable for general park visitors.
    # OSM keys: highway (value "ford"), ford (any value present)
    highway != "ford",
    is.na(ford),

    # ORS rule: highway = track AND tracktype > grade3 -> Reject
    # NO MODIFICATION, same threshold as ORS. grade3 tracks (hard or
    # mixed surface) are drivable by regular passenger vehicles and may
    # be the only access route to rural parks.
    # OSM keys: highway (value "track"), tracktype (values grade1 to grade5)
    !(highway == "track" & !is.na(track_num) & track_num > 3),

    # ORS rule: impassable = yes OR [status, smoothness] = impassable -> Reject
    # NO MODIFICATION.
    # OSM keys: impassable, status (deprecated but still checked by ORS),
    #           smoothness
    is.na(impassable) | impassable != "yes",
    is.na(smoothness) | smoothness != "impassable",
    is.na(status)     | status     != "impassable",

    # ORS rule: maxwidth < 2 -> Reject
    # NO MODIFICATION. Roads narrower than 2 meters cannot accommodate
    # standard passenger vehicles.
    # OSM key: maxwidth (value in meters)
    is.na(width_num) | width_num >= 2,

    # ORS rule: firstValue = restrictedValues -> Conditional
    # MODIFICATION: hard reject (except forestry, see note above).
    # OSM keys checked in priority order: motorcar, motor_vehicle,
    #   vehicle, access
    is.na(access_val) | !access_val %in% restricted,

    # ORS rule: firstValue = intendedValues -> Accept
    # Roads explicitly tagged as accessible are accepted. Untagged roads
    # (access_val = NA) are also accepted (ORS default behavior).
    # OSM keys: same priority order as above
    is.na(access_val) | access_val %in% intended
  )

message(nrow(roads_filtered), " road segments retained after filtering.")


# =============================================================================
# PART 5: CLIP TO COUNTY BOUNDARY & WRITE OUTPUT
# =============================================================================

# The Overpass bbox query may return road segments extending slightly beyond
# the county boundary. Clip to the official TIGER/Line polygon to ensure
# only roads within the county are retained.

roads_filtered <- roads_filtered %>%
  select(osm_id, name, geometry) %>%
  st_intersection(county_sf %>% select(geometry))

if (!dir.exists(dirname(output_path))) dir.create(dirname(output_path), recursive = TRUE)

st_write(roads_filtered, output_path, delete_dsn = TRUE, quiet = TRUE)

message("Filtered road network written: ", output_path)
