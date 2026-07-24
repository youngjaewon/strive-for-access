# =============================================================================
# 03b_geocode_survey123_access_points.R
# -----------------------------------------------------------------------------
# Strive for Access (SFA) - Park Access Point Dataset pipeline
#
# Purpose:
#   Pull Survey123 responses from all seven regional FeatureServers, geocode
#   the reported park addresses, validate the resulting points against the
#   matched park boundaries, and build the Master Park Access Point Dataset.
#
# Flow (see SFA data flow diagram, Section 3: Park Access Point Dataset):
#   1) Data sources        : Survey123 park addresses, one FeatureServer per region
#   2) Process inputs      : geocode and validate addresses (this script)
#   3) Complete coverage   : 03c / 03d fill parks with no access points
#   4) Output              : access_points/access_points_YYYYMMDD.gpkg
#                            Primary key: access_point_id (12 character hex,
#                            same format as park_id)
#                            Foreign key: park_id, several access points may
#                            share one park
#
# Status
#   No master access point file exists yet, so this run creates the dataset
#   from scratch. Deduplication therefore runs within the geocoded points
#   themselves rather than against an existing master.
#
# Workflow
#   1. Pull and merge the seven regional Survey123 downloads
#   2. Drop responses left at the region's default map location
#   3. Match responses to parks (point in polygon, park_id)
#   4. Prepare addresses; multiple or missing addresses go to review
#   5. Geocode with ArcGIS, retry failures with OSM
#   6. QC: keep points inside NC and within max_park_dist of the matched park
#   7. Deduplicate points of the same park within dedupe_dist of each other
#   8. Assign access_point_id values and write the versioned master
#
# Review objects left in the environment: address_review, processing_summary.
# The access point master is the only file written.
# =============================================================================

# --- Packages ----------------------------------------------------------------

library(arcgislayers)
library(tidyverse)
library(sf)
library(tidygeocoder)
library(ids)

source("./Scripts/template/match_survey_to_master.R")


# =============================================================================
# CONFIG (check paths, then run)
# =============================================================================

root <- "/Users/ywon3/Library/CloudStorage/Dropbox/03_Strive for Access/Data"

# Input and output files. Update these two lines before each run. Adding a
# _1, _2 suffix keeps repeated runs on the same day from overwriting.
boundary_path <- file.path(root, "master", "boundaries", "boundaries_20260721.gpkg")
output_path   <- file.path(root, "master", "access_points", "access_points_20260723.gpkg")

# Source metadata recorded on output rows
src_name    <- "Survey123"
creator     <- "youngjaewon"
create_time <- as.POSIXct(paste(Sys.Date(), "12:00:00"), tz = "America/New_York")

crs_projected       <- 32119   # NAD83 North Carolina, meters
default_tolerance_m <- 25      # responses this close to the region default are dropped
max_park_dist       <- 100     # geocoded point must fall within this distance (m) of its park
dedupe_dist         <- 30      # points of one park closer than this (m) collapse to one
page_size           <- 500     # FeatureServer paging size
print_rows          <- 25      # console preview length

# --- Regional Survey123 FeatureServers ---------------------------------------

survey_regions <- tribble(
  ~region,          ~url,
  "Pilot",          "https://services1.arcgis.com/aT1T0pU1ZdpuDk1t/arcgis/rest/services/survey123_1a3132b5c132457e8624be6c803862c8_results/FeatureServer",
  "Central North",  "https://services1.arcgis.com/aT1T0pU1ZdpuDk1t/arcgis/rest/services/survey123_b0970fafced140c3b34d6e0707f4e6dd_results/FeatureServer",
  "Central South",  "https://services1.arcgis.com/aT1T0pU1ZdpuDk1t/arcgis/rest/services/survey123_f8b28bb4b9494b50b3eb7a172161f981_results/FeatureServer",
  "Northeast",      "https://services1.arcgis.com/aT1T0pU1ZdpuDk1t/arcgis/rest/services/survey123_27b5568b85fc417296c92a648799febb_results/FeatureServer",
  "Southeast",      "https://services1.arcgis.com/aT1T0pU1ZdpuDk1t/arcgis/rest/services/survey123_a81fddeeb9fb450980ce2f6ca6ecc8ee_results/FeatureServer",
  "Triad",          "https://services1.arcgis.com/aT1T0pU1ZdpuDk1t/arcgis/rest/services/survey123_c346d074629346e1b83a67693e60ff69_results/FeatureServer",
  "West",           "https://services1.arcgis.com/aT1T0pU1ZdpuDk1t/arcgis/rest/services/survey123_c31f8f893fe141aaa2be359a4a98dbd7_results/FeatureServer"
)

# --- Default map locations per region ----------------------------------------
# A response still at the default point was never moved by the respondent, so
# its location is meaningless and the park match cannot be trusted. Pilot and
# Triad have no recorded default, so no exclusion applies there.

default_locations <- tribble(
  ~region,          ~def_lat,   ~def_lon,
  "Southeast",      34.875946,  -77.716970,
  "West",           35.637734,  -82.670282,
  "Central South",  35.056009,  -79.889821,
  "Central North",  35.999763,  -80.805349,
  "Northeast",      36.068863,  -77.497242
)


# =============================================================================
# PART 1: HELPERS
# =============================================================================

# 12 character hexadecimal identifiers, the same format as park_id.
generate_access_point_ids <- function(n, existing_ids = character()) {
  if (n == 0) return(character())
  out <- character()
  while (length(out) < n) {
    cand <- unique(ids::random_id(n = n - length(out), bytes = 6))
    out <- c(out, cand[!cand %in% existing_ids & !cand %in% out])
  }
  out
}


# =============================================================================
# PART 2: LOAD DATA
# =============================================================================

message("Reading Survey123 responses from ", nrow(survey_regions), " regions")

survey_list <- map2(survey_regions$region, survey_regions$url, \(rg, url) {
  message("  ", rg)
  arc_open(url) |>
    get_layer(id = 0) |>
    arc_select(page_size = page_size) |>
    mutate(region = rg, .before = 1)
})

survey_data <- bind_rows(survey_list)

stopifnot(inherits(survey_data, "sf"), nrow(survey_data) > 0)
if (is.na(st_crs(survey_data))) survey_data <- st_set_crs(survey_data, 4326)

cat("\nResponses pulled by region:\n")
print(count(st_drop_geometry(survey_data), region))

message("Reading master boundaries: ", boundary_path)
boundaries <- st_read(boundary_path, quiet = TRUE)
stopifnot("park_id" %in% names(boundaries))


# =============================================================================
# PART 3: DROP DEFAULT LOCATION RESPONSES
# =============================================================================

survey_data <- survey_data |>
  left_join(default_locations, by = "region") |>
  mutate(
    default_geom = st_sfc(
      map2(def_lon, def_lat, \(x, y) if (is.na(x)) st_point() else st_point(c(x, y))),
      crs = 4326
    ),
    dist_to_default = as.numeric(
      st_distance(st_transform(geometry, 4326), default_geom, by_element = TRUE)
    ),
    at_default = !is.na(dist_to_default) & dist_to_default <= default_tolerance_m
  )

cat("\nResponses at the default location, excluded by region:\n")
print(survey_data |> st_drop_geometry() |> filter(at_default) |> count(region))

survey_data <- survey_data |>
  filter(!at_default) |>
  select(-def_lat, -def_lon, -default_geom, -dist_to_default, -at_default)

cat("Responses retained after the default location filter:", nrow(survey_data), "\n")


# =============================================================================
# PART 4: MATCH RESPONSES TO PARKS AND PREPARE ADDRESSES
# =============================================================================

survey_matched <- match_survey_to_master(
  survey_data     = survey_data,
  master_polygons = boundaries
)

survey_addresses <- survey_matched |>
  filter(match_status == "matched") |>
  st_drop_geometry() |>
  transmute(
    survey_row_id,
    survey_globalid  = globalid,
    region,
    park_id,
    master_park_name,
    survey_park_name = Park_Name,
    address_raw      = park_address
  ) |>
  mutate(
    address_text = address_raw |> str_replace_all("[\r\n]+", " ") |> str_squish(),
    
    # Street number patterns flag responses holding several addresses at once
    address_count = str_count(coalesce(address_text, ""), "\\b\\d{1,6}\\s+[A-Za-z]"),
    
    address_status = case_when(
      is.na(address_text) | address_text == "" ~ "missing_address",
      address_count == 0L                      ~ "no_street_address",
      address_count > 1L                       ~ "multiple_addresses",
      TRUE                                     ~ "ready"
    ),
    
    # Add North Carolina when state information is missing
    geocode_address = case_when(
      address_status != "ready" ~ NA_character_,
      str_detect(address_text, regex("\\bNC\\b|North Carolina", ignore_case = TRUE)) ~ address_text,
      TRUE ~ paste(address_text, "North Carolina", sep = ", ")
    )
  )

addresses_ready <- survey_addresses |>
  filter(address_status == "ready") |>
  mutate(address_id = row_number())

cat("\nAddress status of matched responses:\n")
print(count(survey_addresses, address_status))


# =============================================================================
# PART 5: GEOCODE (ArcGIS, then OSM for failures)
# =============================================================================

geocoded_arcgis <- addresses_ready |>
  geocode(address = geocode_address, method = "arcgis",
          lat = latitude, long = longitude, limit = 1, quiet = TRUE) |>
  mutate(geocode_service = if_else(!is.na(latitude) & !is.na(longitude), "arcgis", NA_character_))

arcgis_failures <- geocoded_arcgis |> filter(is.na(latitude) | is.na(longitude))

geocoded_osm <- if (nrow(arcgis_failures) > 0) {
  arcgis_failures |>
    select(-latitude, -longitude, -geocode_service) |>
    geocode(address = geocode_address, method = "osm",
            lat = latitude, long = longitude, limit = 1, quiet = TRUE) |>
    mutate(geocode_service = if_else(!is.na(latitude) & !is.na(longitude), "osm", NA_character_))
} else {
  geocoded_arcgis |> slice(0)
}

geocoded_addresses <- bind_rows(
  geocoded_arcgis |> filter(!is.na(latitude) & !is.na(longitude)),
  geocoded_osm
) |>
  distinct(address_id, .keep_all = TRUE) |>
  arrange(address_id) |>
  mutate(geocode_status = if_else(!is.na(latitude) & !is.na(longitude),
                                  "geocoded", "geocode_failed"))

geocoded_points <- geocoded_addresses |>
  filter(geocode_status == "geocoded") |>
  st_as_sf(coords = c("longitude", "latitude"), crs = 4326, remove = FALSE) |>
  st_transform(crs_projected)

cat("\nGeocoded:", nrow(geocoded_points), "of", nrow(addresses_ready),
    "ready addresses\n")


# =============================================================================
# PART 6: QUALITY CHECKS
# =============================================================================
# A point is valid when it lies inside North Carolina and within max_park_dist
# of the park its survey response was matched to.

boundaries_qc <- boundaries |>
  select(park_id) |>
  st_transform(crs_projected)

park_row <- match(geocoded_points$park_id, boundaries_qc$park_id)

geocoded_points$park_distance_m <- as.numeric(
  st_distance(geocoded_points, boundaries_qc[park_row, ], by_element = TRUE)
)

geocoded_points <- geocoded_points |>
  mutate(
    inside_nc = latitude >= 33.8 & latitude <= 36.7 &
      longitude >= -84.4 & longitude <= -75.3,
    qc_status = case_when(
      !inside_nc                       ~ "outside_nc",
      park_distance_m <= max_park_dist ~ "valid",
      TRUE                             ~ "review_distance"
    )
  )

points_valid <- geocoded_points |> filter(qc_status == "valid")

cat("QC passed:", nrow(points_valid), "of", nrow(geocoded_points),
    "geocoded points (inside NC, within", max_park_dist, "m of matched park)\n")


# =============================================================================
# PART 7: DEDUPLICATE WITHIN THE NEW DATASET
# =============================================================================
# No master exists yet, so deduplication runs among the new points themselves:
# within one park, points closer than dedupe_dist collapse to the first one.
# Different parks never deduplicate against each other.

points_valid <- points_valid |> mutate(point_row = row_number())

dup_rows <- points_valid |>
  st_drop_geometry() |>
  distinct(park_id) |>
  pull(park_id) |>
  map(\(pid) {
    grp <- points_valid |> filter(park_id == pid)
    if (nrow(grp) < 2) return(integer())
    d <- st_distance(grp) |> units::drop_units()
    keep <- rep(TRUE, nrow(grp))
    for (i in seq_len(nrow(grp))[-1]) {
      if (any(d[i, seq_len(i - 1)][keep[seq_len(i - 1)]] <= dedupe_dist)) keep[i] <- FALSE
    }
    grp$point_row[!keep]
  }) |>
  unlist()

points_new <- points_valid |> filter(!point_row %in% dup_rows)

cat("Duplicates removed within parks (", dedupe_dist, " m rule): ",
    length(dup_rows), "; access points retained: ", nrow(points_new), "\n", sep = "")


# =============================================================================
# PART 8: BUILD THE MASTER AND REVIEW TABLES
# =============================================================================

access_points <- points_new |>
  transmute(
    access_point_id = generate_access_point_ids(n()),
    park_id,
    MA_NAME         = master_park_name,   # park name from the boundary master
    region,
    geocode_address,
    geocode_service,
    GIS_SRC         = src_name,
    Creator         = creator,
    CreationDate    = create_time
  ) |>
  st_transform(4326)

# Records needing manual work: unusable addresses, geocoding failures, and
# geocoded points that failed QC.
address_review <- bind_rows(
  survey_addresses |>
    filter(address_status != "ready") |>
    transmute(survey_row_id, survey_globalid, region, park_id, master_park_name,
              survey_park_name, address_raw, geocode_address,
              geocode_service = NA_character_,
              latitude = NA_real_, longitude = NA_real_,
              park_distance_m = NA_real_, qc_status = address_status),
  geocoded_addresses |>
    filter(geocode_status == "geocode_failed") |>
    transmute(survey_row_id, survey_globalid, region, park_id, master_park_name,
              survey_park_name, address_raw, geocode_address, geocode_service,
              latitude, longitude,
              park_distance_m = NA_real_, qc_status = "geocode_failed"),
  geocoded_points |>
    filter(qc_status != "valid") |>
    st_drop_geometry() |>
    transmute(survey_row_id, survey_globalid, region, park_id, master_park_name,
              survey_park_name, address_raw, geocode_address, geocode_service,
              latitude, longitude, park_distance_m, qc_status)
) |>
  arrange(region, survey_row_id)


# =============================================================================
# PART 9: REVIEW RESULTS (console only)
# =============================================================================

processing_summary <- tibble(
  stage = c(
    "Responses matched to one park",
    "Single addresses ready for geocoding",
    "Addresses successfully geocoded",
    "Points passing QC",
    "Access points after within park dedupe",
    "Records requiring review"
  ),
  n = c(
    nrow(survey_addresses),
    nrow(addresses_ready),
    nrow(geocoded_points),
    nrow(points_valid),
    nrow(access_points),
    nrow(address_review)
  )
)

print(processing_summary)

cat("\nAccess points by region:\n")
print(access_points |> st_drop_geometry() |> count(region))

cat("\nAccess points per park:\n")
print(access_points |> st_drop_geometry() |> count(park_id) |> count(n, name = "n_parks"))

cat("\nQC status by geocoding service:\n")
print(geocoded_points |> st_drop_geometry() |> count(qc_status, geocode_service))

if (nrow(address_review) > 0) {
  cat("\nFirst", min(print_rows, nrow(address_review)),
      "review records (see the object address_review for all):\n")
  print(head(address_review, print_rows))
}


# =============================================================================
# PART 10: WRITE VERSIONED OUTPUT
# =============================================================================

# Sanity checks before writing
stopifnot(!any(is.na(access_points$access_point_id)))
stopifnot(!any(duplicated(access_points$access_point_id)))
stopifnot(!any(is.na(access_points$park_id)))
stopifnot(all(access_points$park_id %in% boundaries$park_id))
stopifnot(!file.exists(output_path))

if (!dir.exists(dirname(output_path))) dir.create(dirname(output_path), recursive = TRUE)

st_write(access_points, output_path, layer = "access_points", delete_dsn = TRUE, quiet = TRUE)

message("Master Park Access Point Dataset written: ", output_path)
message("Access points: ", nrow(access_points),
        " across ", n_distinct(access_points$park_id), " parks")