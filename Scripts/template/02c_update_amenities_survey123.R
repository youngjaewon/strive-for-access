# =============================================================================
# 02c_update_amenities_survey123.R
# -----------------------------------------------------------------------------
# Strive for Access (SFA) - Park Amenity Dataset pipeline
#
# Purpose:
#   Pull Survey123 amenity responses from all seven regional FeatureServers,
#   merge them into one point dataset, drop untrustworthy responses left at the
#   region's default map location, match the remaining points to master park
#   boundaries, summarize duplicate responses, and merge the results into the
#   Master Park Amenity Dataset.
#
# Flow (see SFA data flow diagram, Section 2: Park Amenity Dataset):
#   1) Data sources      : Survey123 responses, one FeatureServer per region
#   2) Process amenities : merge regions, drop default location points
#   3) Link to parks     : point in polygon match to park_id
#   4) Output            : amenities/amenities_YYYYMMDD.xlsx
#
# Default location rule
#   Each regional survey opens on a default map point. A response still sitting
#   at that point means the respondent never moved the pin, so the location
#   carries no information. Responses within default_tolerance_m of their
#   region's default point are excluded. Pilot and Triad have no recorded
#   default, so no exclusion applies there.
#
# Duplicate response rules
#   All responses matched to the same park are summarized together.
#     yes_no fields : Yes if at least one response is Yes,
#                     No if all valid responses are No.
#     count fields  : maximum reported value.
#
# Update rule
#   Only a survey Yes writes to the master. A survey No never overwrites, and
#   a missing survey value is treated as not reviewed. Count fields have no Yes
#   value, so any reported count replaces the master value.
#
# Review objects left in the environment: changelog, unmatched, region_summary.
# The amenity table is the only file written.
# =============================================================================

# --- Packages ----------------------------------------------------------------

library(arcgislayers)
library(tidyverse)
library(sf)
library(readxl)
library(writexl)

source("./Scripts/template/match_survey_to_master.R")


# =============================================================================
# CONFIG (check paths, then run)
# =============================================================================

root <- "/Users/ywon3/Library/CloudStorage/Dropbox/03_Strive for Access/Data"

# Input and output files. Update these three lines before each run. Adding a
# _1, _2 suffix keeps repeated runs on the same day from overwriting.
boundary_path  <- file.path(root, "master", "boundaries", "boundaries_20260721.gpkg")
amenities_path <- file.path(root, "master", "amenities", "amenities_20260723_1.xlsx")
output_path    <- file.path(root, "master", "amenities", "amenities_20260723_2.xlsx")

page_size           <- 500   # FeatureServer paging size
default_tolerance_m <- 25    # points within this distance of the region default are dropped
print_rows          <- 25    # console preview length

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
# Pilot and Triad have no recorded default, so their responses are never
# excluded by the default location rule.

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

# Reading all columns as text avoids the type guessing warnings raised when a
# column is empty in the first 1000 rows and holds text further down.
read_amenity_table <- function(path) {
  ext <- str_to_lower(tools::file_ext(path))
  out <- if (ext %in% c("xlsx", "xlsm", "xls")) {
    read_excel(path, col_types = "text")
  } else if (ext == "csv") {
    read_csv(path, col_types = cols(.default = col_character()))
  } else {
    stop("Unsupported amenity table format: ", ext)
  }
  num <- str_detect(names(out), regex("count$|mileage$|^acres$", ignore_case = TRUE))
  out |> mutate(across(all_of(names(out)[num]), ~ suppressWarnings(as.numeric(.x))))
}

# Yes if any valid response is Yes, No if all valid responses are No, else NA.
summarise_yes_no <- function(x) {
  x <- str_to_lower(str_squish(as.character(x)))
  x <- x[!is.na(x) & x != ""]
  if (length(x) == 0) return(NA_character_)
  if (any(x == "yes")) return("Yes")
  if (all(x == "no")) return("No")
  NA_character_
}

# Maximum valid count, NA if there are no valid responses.
summarise_count <- function(x) {
  x <- suppressWarnings(as.numeric(x))
  x <- x[!is.na(x)]
  if (length(x) == 0) NA_real_ else max(x)
}


# =============================================================================
# PART 2: LOAD DATA
# =============================================================================

# --- 2.1 Pull and merge all regional Survey123 responses ---------------------

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

# --- 2.2 Load master boundaries and amenity table ----------------------------

message("Reading master boundaries: ", boundary_path)
boundaries <- st_read(boundary_path, quiet = TRUE)

message("Reading amenity table: ", amenities_path)
amenities <- read_amenity_table(amenities_path)

stopifnot("park_id" %in% names(boundaries))
stopifnot("park_id" %in% names(amenities))
stopifnot(!any(duplicated(amenities$park_id)))

cat("\nMaster boundaries:", nrow(boundaries),
    "\nAmenity records: ", nrow(amenities),
    "\nSurvey responses:", nrow(survey_data), "\n")


# =============================================================================
# PART 3: DROP DEFAULT LOCATION RESPONSES
# =============================================================================
# A point still at the region's default location was never moved by the
# respondent, so its position is meaningless and the response is excluded.

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
print(
  survey_data |>
    st_drop_geometry() |>
    filter(at_default) |>
    count(region)
)

survey_data <- survey_data |>
  filter(!at_default) |>
  select(-def_lat, -def_lon, -default_geom, -dist_to_default, -at_default)

cat("Responses retained after the default location filter:", nrow(survey_data), "\n")


# =============================================================================
# PART 4: FIELD MAPPING
# =============================================================================

# --- 4.1 Survey123 to master field mapping -----------------------------------
# Edit this table when fields need to be added or changed.

amenity_map <- tribble(
  ~survey_field,                     ~master_field,                 ~value_type,
  
  # Facility presence fields
  "aircraft_flying",                 "AircraftFlying",              "yes_no",
  "fitnesschallenge_course",         "Fitness_ChallengeCourse",     "yes_no",
  "climbing_wallbouldering",         "ClimbingWall",                "yes_no",
  "low_ropes_course",                "LowRopes",                    "yes_no",
  "high_ropes_course",               "HighRopes",                   "yes_no",
  "shooting_range",                  "ShootingRange",               "yes_no",
  "skate_park",                      "SkatePark",                   "yes_no",
  "snow_ice_activities",             "SnowAndIce",                  "yes_no",
  "pump_track",                      "PumpTrack",                   "yes_no",
  "Carousel",                        "Carousel",                    "yes_no",
  "miniature_train",                 "MiniTrain",                   "yes_no",
  "batting_cage",                    "BatCage",                     "yes_no",
  "disc_golf",                       "DiscGolf",                    "yes_no",
  "golf_driving_range",              "DrivingRange",                "yes_no",
  "golf_course",                     "GolfCourse",                  "yes_no",
  "basketball_court",                "BasketballCourt",             "yes_no",
  "multipurpose_court",              "MultipurposeCourt",           "yes_no",
  "pickleball_courts",               "PickleballCourt",             "yes_no",
  "tennis_courts",                   "TennisCourt",                 "yes_no",
  "sand_volleyball",                 "VolleyballSand",              "yes_no",
  "volleyball_other",                "VolleyballOther",             "yes_no",
  "cricket_field",                   "CricketField",                "yes_no",
  "diamond_athletic_field",          "DiamondField",                "yes_no",
  "inclusive_diamond_field",         "InclusiveDiamond",            "yes_no",
  "running_track",                   "RunningTrack",                "yes_no",
  "MiniGolf",                        "MiniGolf",                    "yes_no",
  "lawn_games",                      "YardGames",                   "yes_no",
  "table_games",                     "TableGames",                  "yes_no",
  "playground",                      "Playground",                  "yes_no",
  "amphitheater_stage",              "Amphitheater",                "yes_no",
  "foodTruck_infrastructure",        "FoodTruck",                   "yes_no",
  "picnic_shelter",                  "PicnicShelter",               "yes_no",
  "dog_park",                        "DogPark",                     "yes_no",
  "equestrian_center",               "Equestrian",                  "yes_no",
  "cabins",                          "Cabins",                      "yes_no",
  "primitive_campsites",             "PrimitiveCamp",               "yes_no",
  "rv_campsites",                    "RV_camping",                  "yes_no",
  "tent_campsites",                  "Tent_camping",                "yes_no",
  "boat_ramp",                       "BoatRamp",                    "yes_no",
  "paddle_access",                   "BluewayPaddle",               "yes_no",
  "equestrian_or_bridle_trails",     "EquestrianTrail",             "yes_no",
  "mountain_bike_trails",            "MountainBike",                "yes_no",
  "swimming_pool",                   "SwimPool",                    "yes_no",
  "splashpad",                       "Sprayground",                 "yes_no",
  
  # Facility count fields
  "BatCageCount",                    "BatCageCount",                "count",
  "basketball_count",                "BasketballCount",             "count",
  "multipurpose_count",              "MultipurposeCount",           "count",
  "pickleball_count",                "PickleballCount",             "count",
  "tennis_count",                    "TennisCount",                 "count",
  "volleyballsand_count",            "VolleyballSandCount",         "count",
  "volleyballother_count",           "VolleyballOtherCount",        "count",
  "cricket_count",                   "CricketCount",                "count",
  "diamond_field_count",             "DiamondFieldCount",           "count",
  "includiamond_count",              "InclusiveDiamondCount",       "count",
  "number_of_cabins",                "CabinCount",                  "count",
  "primitiveSite_Count",             "PrimitiveSiteCount",          "count",
  "RVsite_Count",                    "RvSiteCount",                 "count",
  "tentSites_Count",                 "TentSiteCount",               "count",
  "picnic_shelter_count",            "PicnicShelterCount",          "count",
  "RampCount",                       "BoatRampCount",               "count",
  "playground_count",                "PlaygroundCount",             "count",
  "total_number_of_holes",           "Disc_golf_hole_count",        "count",
  "total_miles_of_equestrian_trail", "equestrian_mileage",          "count",
  "total_miles_of_mountain_bike_tr", "mountain_bike_mileage",       "count"
)

# --- 4.2 Validate mapped fields ----------------------------------------------
# A field missing from one region is filled with NA by bind_rows, so the check
# runs against the merged dataset.

mapping_problem <- amenity_map |>
  mutate(
    survey_exists = survey_field %in% names(survey_data),
    master_exists = master_field %in% names(amenities)
  ) |>
  filter(!survey_exists | !master_exists)

if (nrow(mapping_problem) > 0) {
  print(mapping_problem)
  stop("One or more mapped fields are missing from Survey123 or the amenity table.")
}


# =============================================================================
# PART 5: MATCH SURVEY POINTS TO PARKS
# =============================================================================

survey_matched <- match_survey_to_master(
  survey_data     = survey_data,
  master_polygons = boundaries
)

unmatched <- survey_matched |>
  st_drop_geometry() |>
  filter(match_status != "matched") |>
  distinct(
    survey_row_id, region, match_status, match_count,
    pick(any_of(c("objectid", "globalid", "Park_Name", "park_name_copy", "park_address")))
  )

if (nrow(unmatched) > 0) {
  cat("\nResponses not matched to exactly one park (review manually):\n")
  print(head(unmatched, print_rows))
}


# =============================================================================
# PART 6: SUMMARIZE RESPONSES AND UPDATE THE AMENITY TABLE
# =============================================================================

# --- 6.1 Summarize duplicate responses by park -------------------------------

yes_no_fields <- amenity_map |> filter(value_type == "yes_no") |> pull(survey_field)
count_fields  <- amenity_map |> filter(value_type == "count")  |> pull(survey_field)

survey_summary <- survey_matched |>
  st_drop_geometry() |>
  filter(match_status == "matched") |>
  group_by(park_id) |>
  summarise(
    across(all_of(yes_no_fields), summarise_yes_no),
    across(all_of(count_fields), summarise_count),
    response_count = n(),
    .groups = "drop"
  )

cat("\nParks with at least one matched response:", nrow(survey_summary), "\n")
cat("Responses per matched park:\n")
print(table(survey_summary$response_count))

# --- 6.2 Rename survey fields to master fields and merge ---------------------
# Presence fields are additive: only a survey Yes writes to the master, so a
# survey No can never erase an existing Yes. Count fields have no Yes value,
# so any reported count replaces the master value.

update_wide <- survey_summary |>
  select(park_id, all_of(amenity_map$survey_field)) |>
  rename(!!!setNames(amenity_map$survey_field, amenity_map$master_field))

amenities_updated <- amenities |>
  left_join(update_wide, by = "park_id", suffix = c("", ".src"))

changelog <- list()

for (i in seq_len(nrow(amenity_map))) {
  fld        <- amenity_map$master_field[i]
  value_type <- amenity_map$value_type[i]
  src_col    <- paste0(fld, ".src")
  if (!src_col %in% names(amenities_updated)) next
  
  current  <- amenities_updated[[fld]]
  incoming <- amenities_updated[[src_col]]
  
  writable <- if (value_type == "yes_no") {
    !is.na(incoming) & incoming == "Yes"
  } else {
    !is.na(incoming)
  }
  
  idx <- which(writable & (is.na(current) | current != incoming))
  
  if (length(idx) > 0) {
    changelog[[fld]] <- tibble(
      park_id      = amenities_updated$park_id[idx],
      MA_NAME      = as.character(amenities_updated$MA_NAME[idx]),
      master_field = fld,
      value_type   = value_type,
      old_value    = as.character(current[idx]),
      new_value    = as.character(incoming[idx])
    )
    current[idx] <- incoming[idx]
    amenities_updated[[fld]] <- current
  }
  
  amenities_updated[[src_col]] <- NULL
}

changelog <- bind_rows(changelog)


# =============================================================================
# PART 7: REVIEW RESULTS (console only)
# =============================================================================

region_summary <- survey_matched |>
  st_drop_geometry() |>
  distinct(survey_row_id, region, match_status) |>
  count(region, match_status) |>
  pivot_wider(names_from = match_status, values_from = n, values_fill = 0)

cat("\nMatch status by region:\n")
print(region_summary)

cat("\nAmenity cells updated:", nrow(changelog), "\n")

if (nrow(changelog) > 0) {
  cat("\nUpdates by column:\n")
  print(count(changelog, value_type, master_field, sort = TRUE), n = Inf)
  
  # Presence fields can only gain a Yes, but a count can be revised downward.
  # Those cells are the ones worth a second look.
  count_drops <- changelog |>
    filter(value_type == "count", !is.na(old_value)) |>
    filter(suppressWarnings(as.numeric(new_value) < as.numeric(old_value)))
  
  if (nrow(count_drops) > 0) {
    cat("\nCounts revised downward (", nrow(count_drops), " cells):\n", sep = "")
    print(head(count_drops, print_rows))
  }
  
  cat("\nFirst", min(print_rows, nrow(changelog)), "changed cells (see changelog for all):\n")
  print(head(changelog, print_rows))
}


# =============================================================================
# PART 8: WRITE VERSIONED OUTPUT
# =============================================================================

# Sanity checks before writing
stopifnot(!any(is.na(amenities_updated$park_id)))
stopifnot(!any(duplicated(amenities_updated$park_id)))
stopifnot(nrow(amenities_updated) == nrow(amenities))

stopifnot(!file.exists(output_path))

write_xlsx(amenities_updated, output_path)

message("Master Park Amenity Dataset written: ", output_path)
message("Parks in table: ", nrow(amenities_updated),
        " (", nrow(survey_summary), " parks updated from Survey123, ",
        nrow(changelog), " cells changed)")