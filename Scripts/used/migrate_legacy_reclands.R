# =============================================================================
# 00_migrate_legacy_reclands.R
# =============================================================================
# One time migration from the legacy combined RecLands dataset to the current
# SFA master data structure.
#
# Outputs
#   1. Master Park Boundary Dataset
#      One record per park_id with MULTIPOLYGON geometry
#
#   2. Master Park Amenity Dataset
#      One record per park_id with no geometry
#
#   3. Migration review tables
#      Empty geometry records, duplicate identifiers, attribute conflicts,
#      and a legacy to current identifier crosswalk
#
# The script uses SiteID as the legacy grouping key, with GlobalID as a
# fallback. It then assigns one new 12 character park_id to each unique legacy
# key using ids::random_id(bytes = 6).
# =============================================================================

library(tidyverse)
library(sf)
library(ids)
library(writexl)

# =============================================================================
# CONFIG
# =============================================================================

root <- "./Data/master"

legacy_path <- file.path(
  root,
  "boundaries",
  "RecLandsAll20260511.geojson"
)

version_date <- as.Date("2026-05-11")
date_stamp <- format(version_date, "%Y%m%d")

boundary_dir <- file.path(root, "boundaries")
amenity_dir <- file.path(root, "amenities")
review_dir <- file.path(root, "migration_review")

boundary_output <- file.path(
  boundary_dir,
  paste0("boundaries_", date_stamp, ".gpkg")
)

amenity_output <- file.path(
  amenity_dir,
  paste0("amenities_", date_stamp, ".xlsx")
)

empty_geometry_output <- file.path(
  review_dir,
  paste0("boundary_empty_geometry_", date_stamp, ".csv")
)

duplicate_id_output <- file.path(
  review_dir,
  paste0("boundary_duplicate_id_", date_stamp, ".csv")
)

attribute_conflict_output <- file.path(
  review_dir,
  paste0("boundary_attribute_conflict_", date_stamp, ".csv")
)

crosswalk_output <- file.path(
  review_dir,
  paste0("legacy_id_crosswalk_", date_stamp, ".csv")
)

# NAD83 North Carolina, meters
crs_projected <- 32119
crs_output <- 4326


# =============================================================================
# MASTER SCHEMAS
# =============================================================================

boundary_fields <- c(
  "MA_ID",
  "MA_NAME",
  "OWNER",
  "OWNER_TYPE",
  "CATEGORY",
  "GIS_SRC",
  "SRC_DATE",
  "DATA_DATE",
  "CreationDate",
  "Creator",
  "EditDate",
  "Editor"
)

# Fields used by 02c_update_amenities_survey123.R
amenity_yes_no_fields <- c(
  "AircraftFlying",
  "Fitness_ChallengeCourse",
  "ClimbingWall",
  "LowRopes",
  "HighRopes",
  "ShootingRange",
  "SkatePark",
  "SnowAndIce",
  "PumpTrack",
  "Carousel",
  "MiniTrain",
  "BatCage",
  "DiscGolf",
  "DrivingRange",
  "GolfCourse",
  "BasketballCourt",
  "MultipurposeCourt",
  "PickleballCourt",
  "TennisCourt",
  "VolleyballSand",
  "VolleyballOther",
  "CricketField",
  "DiamondField",
  "InclusiveDiamond",
  "RunningTrack",
  "MiniGolf",
  "YardGames",
  "TableGames",
  "Playground",
  "Amphitheater",
  "FoodTruck",
  "PicnicShelter",
  "DogPark",
  "Equestrian",
  "Cabins",
  "PrimitiveCamp",
  "RV_camping",
  "Tent_camping",
  "BoatRamp",
  "BluewayPaddle",
  "EquestrianTrail",
  "MountainBike",
  "SwimPool",
  "Sprayground",
  
  # Legacy fields retained so information is not lost during migration
  "HuntBlinds",
  "MarinaLake",
  "LakeAccess",
  "SwimOcean",
  "SwimLake",
  "WaterPark",
  "Boardwalk"
)

amenity_count_fields <- c(
  "BatCageCount",
  "BasketballCount",
  "MultipurposeCount",
  "PickleballCount",
  "TennisCount",
  "VolleyballSandCount",
  "VolleyballOtherCount",
  "CricketCount",
  "DiamondFieldCount",
  "InclusiveDiamondCount",
  "CabinCount",
  "PrimitiveSiteCount",
  "RvSiteCount",
  "TentSiteCount",
  "PicnicShelterCount",
  "BoatRampCount",
  "PlaygroundCount",
  "Disc_golf_hole_count"
)

amenity_distance_fields <- c(
  "equestrian_mileage",
  "mountain_bike_mileage"
)

amenity_selection_fields <- c(
  "YardGameSelect",
  "table_games_selection"
)

amenity_text_fields <- c(
  "table_games_selection_other",
  "Other"
)

all_amenity_fields <- c(
  amenity_yes_no_fields,
  amenity_count_fields,
  amenity_distance_fields,
  amenity_selection_fields,
  amenity_text_fields
)


# =============================================================================
# HELPERS
# =============================================================================

normalize_legacy_id <- function(x) {
  x |>
    as.character() |>
    str_remove_all("[{}]") |>
    str_to_lower() |>
    str_squish() |>
    na_if("")
}

generate_park_ids <- function(n, existing_ids = character()) {
  if (n == 0) return(character())
  
  new_ids <- character()
  
  while (length(new_ids) < n) {
    candidates <- ids::random_id(
      n = n - length(new_ids),
      bytes = 6
    ) |>
      unique()
    
    candidates <- candidates[
      !candidates %in% existing_ids &
        !candidates %in% new_ids
    ]
    
    new_ids <- c(new_ids, candidates)
  }
  
  new_ids
}

blank_to_na <- function(x) {
  if (!is.character(x)) return(x)
  x <- str_squish(x)
  na_if(x, "")
}

first_nonmissing <- function(x) {
  if (is.character(x)) x <- blank_to_na(x)
  idx <- which(!is.na(x))
  if (length(idx) > 0) x[idx[1]] else x[NA_integer_][1]
}

normalize_yes_no <- function(x) {
  value <- x |>
    as.character() |>
    str_squish() |>
    str_to_lower()
  
  case_when(
    value %in% c("yes", "y", "true", "1") ~ "Yes",
    value %in% c("no", "n", "false", "0") ~ "No",
    TRUE ~ NA_character_
  )
}

summarize_yes_no <- function(x) {
  if (any(x == "Yes", na.rm = TRUE)) return("Yes")
  if (any(x == "No", na.rm = TRUE)) return("No")
  NA_character_
}

max_or_na <- function(x) {
  x <- suppressWarnings(readr::parse_number(as.character(x)))
  if (all(is.na(x))) NA_real_ else max(x, na.rm = TRUE)
}

collapse_unique <- function(x) {
  x <- x |>
    as.character() |>
    str_squish() |>
    na_if("") |>
    unique() |>
    na.omit()
  
  if (length(x) == 0) NA_character_ else paste(x, collapse = " | ")
}

add_missing_character_fields <- function(data, fields) {
  missing_fields <- setdiff(fields, names(data))
  for (field in missing_fields) data[[field]] <- NA_character_
  data
}

add_missing_numeric_fields <- function(data, fields) {
  missing_fields <- setdiff(fields, names(data))
  for (field in missing_fields) data[[field]] <- NA_real_
  data
}


# =============================================================================
# PART 1: READ LEGACY DATA AND CREATE park_id
# =============================================================================

message("Reading legacy dataset: ", legacy_path)
legacy <- st_read(legacy_path, quiet = TRUE) |>
  mutate(source_row_id = row_number())

stopifnot(!is.na(st_crs(legacy)))

site_id <- if ("SiteID" %in% names(legacy)) {
  normalize_legacy_id(legacy$SiteID)
} else {
  rep(NA_character_, nrow(legacy))
}

global_id <- if ("GlobalID" %in% names(legacy)) {
  normalize_legacy_id(legacy$GlobalID)
} else {
  rep(NA_character_, nrow(legacy))
}

legacy <- legacy |>
  mutate(
    legacy_key = coalesce(
      paste0("siteid:", site_id),
      paste0("globalid:", global_id),
      paste0("row:", source_row_id)
    ),
    park_id_source = case_when(
      !is.na(site_id) ~ "SiteID",
      !is.na(global_id) ~ "GlobalID",
      TRUE ~ "generated_from_row"
    )
  )

id_lookup <- legacy |>
  st_drop_geometry() |>
  distinct(legacy_key) |>
  mutate(
    park_id = generate_park_ids(n())
  )

legacy <- legacy |>
  left_join(id_lookup, by = "legacy_key")

stopifnot(!any(is.na(legacy$park_id)))
stopifnot(!any(duplicated(id_lookup$park_id)))


# =============================================================================
# PART 2: STANDARDIZE CORE ATTRIBUTES
# =============================================================================

legacy_character_fields <- c(
  "MA_ID", "MA_NAME", "Park_Name", "OWNER", "Agency", "OWNER_TYPE",
  "CATEGORY", "GIS_SRC", "SRC_DATE", "Creator", "Editor"
)

legacy_date_fields <- c("DATA_DATE")
legacy_datetime_fields <- c("CreationDate", "EditDate")

legacy <- add_missing_character_fields(legacy, legacy_character_fields)

for (field in setdiff(legacy_date_fields, names(legacy))) {
  legacy[[field]] <- as.Date(NA)
}

for (field in setdiff(legacy_datetime_fields, names(legacy))) {
  legacy[[field]] <- as.POSIXct(NA)
}

legacy <- legacy |>
  mutate(
    MA_ID = as.character(MA_ID),
    MA_NAME = coalesce(
      blank_to_na(as.character(MA_NAME)),
      blank_to_na(as.character(Park_Name))
    ),
    OWNER = coalesce(
      blank_to_na(as.character(OWNER)),
      blank_to_na(as.character(Agency))
    ),
    OWNER_TYPE = blank_to_na(as.character(OWNER_TYPE)),
    CATEGORY = blank_to_na(as.character(CATEGORY)),
    GIS_SRC = blank_to_na(as.character(GIS_SRC)),
    SRC_DATE = blank_to_na(as.character(SRC_DATE)),
    DATA_DATE = as.Date(DATA_DATE),
    CreationDate = as.POSIXct(CreationDate),
    Creator = blank_to_na(as.character(Creator)),
    EditDate = as.POSIXct(EditDate),
    Editor = blank_to_na(as.character(Editor))
  )


# =============================================================================
# PART 3: WRITE MIGRATION REVIEW TABLES
# =============================================================================

for (dir in c(boundary_dir, amenity_dir, review_dir)) {
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE)
}

is_empty_geometry <- st_is_empty(legacy)

empty_geometry_review <- legacy |>
  filter(is_empty_geometry) |>
  st_drop_geometry() |>
  select(
    source_row_id,
    park_id,
    park_id_source,
    any_of(c("SiteID", "GlobalID")),
    MA_ID,
    MA_NAME,
    OWNER,
    GIS_SRC
  )

write_csv(empty_geometry_review, empty_geometry_output, na = "")

duplicate_id_review <- legacy |>
  st_drop_geometry() |>
  count(park_id, name = "source_feature_count") |>
  filter(source_feature_count > 1) |>
  arrange(desc(source_feature_count), park_id)

write_csv(duplicate_id_review, duplicate_id_output, na = "")

conflict_fields <- c("MA_ID", "MA_NAME", "OWNER", "OWNER_TYPE", "CATEGORY")

attribute_conflict_review <- legacy |>
  st_drop_geometry() |>
  group_by(park_id) |>
  summarise(
    across(
      all_of(conflict_fields),
      ~ n_distinct(blank_to_na(as.character(.x)), na.rm = TRUE),
      .names = "{.col}_distinct"
    ),
    .groups = "drop"
  ) |>
  filter(if_any(ends_with("_distinct"), ~ .x > 1))

write_csv(attribute_conflict_review, attribute_conflict_output, na = "")

crosswalk <- legacy |>
  st_drop_geometry() |>
  transmute(
    source_row_id,
    legacy_SiteID = if ("SiteID" %in% names(legacy)) as.character(SiteID) else NA_character_,
    legacy_GlobalID = if ("GlobalID" %in% names(legacy)) as.character(GlobalID) else NA_character_,
    MA_ID,
    MA_NAME,
    park_id,
    park_id_source,
    has_geometry = !is_empty_geometry
  )

write_csv(crosswalk, crosswalk_output, na = "")


# =============================================================================
# PART 4: CREATE MASTER PARK BOUNDARY DATASET
# =============================================================================

boundary_source <- legacy |>
  filter(!is_empty_geometry) |>
  select(park_id, all_of(boundary_fields), geometry) |>
  st_transform(crs_projected) |>
  st_make_valid()

# One park_id becomes one MULTIPOLYGON record. Duplicate source rows with the
# same park_id are dissolved while core attributes retain the first nonmissing
# value. Attribute disagreements are written to the conflict review table.
boundaries <- boundary_source |>
  group_by(park_id) |>
  summarise(
    across(all_of(boundary_fields), first_nonmissing),
    geometry = st_union(geometry),
    .groups = "drop"
  ) |>
  st_make_valid() |>
  st_collection_extract("POLYGON", warn = FALSE) |>
  st_cast("MULTIPOLYGON", warn = FALSE) |>
  mutate(
    ACRES = as.numeric(st_area(geometry)) / 4046.8564224
  ) |>
  select(
    park_id,
    MA_ID,
    MA_NAME,
    OWNER,
    OWNER_TYPE,
    CATEGORY,
    ACRES,
    GIS_SRC,
    SRC_DATE,
    DATA_DATE,
    CreationDate,
    Creator,
    EditDate,
    Editor,
    geometry
  ) |>
  st_transform(crs_output)

stopifnot(!any(is.na(boundaries$park_id)))
stopifnot(!any(duplicated(boundaries$park_id)))
stopifnot(!any(st_is_empty(boundaries)))

st_write(
  boundaries,
  boundary_output,
  layer = "boundaries",
  delete_dsn = TRUE,
  quiet = TRUE
)


# =============================================================================
# PART 5: CREATE MASTER PARK AMENITY DATASET
# =============================================================================

amenity_source <- legacy |>
  st_drop_geometry() |>
  select(park_id, any_of(all_amenity_fields)) |>
  add_missing_character_fields(c(amenity_yes_no_fields, amenity_selection_fields, amenity_text_fields)) |>
  add_missing_numeric_fields(c(amenity_count_fields, amenity_distance_fields)) |>
  mutate(
    across(all_of(amenity_yes_no_fields), normalize_yes_no),
    across(
      all_of(c(amenity_count_fields, amenity_distance_fields)),
      ~ suppressWarnings(readr::parse_number(as.character(.x)))
    ),
    across(
      all_of(c(amenity_selection_fields, amenity_text_fields)),
      ~ blank_to_na(as.character(.x))
    )
  )

amenities <- amenity_source |>
  group_by(park_id) |>
  summarise(
    across(all_of(amenity_yes_no_fields), summarize_yes_no),
    across(
      all_of(c(amenity_count_fields, amenity_distance_fields)),
      max_or_na
    ),
    across(
      all_of(c(amenity_selection_fields, amenity_text_fields)),
      collapse_unique
    ),
    .groups = "drop"
  ) |>
  right_join(
    boundaries |>
      st_drop_geometry() |>
      select(
        park_id,
        MA_NAME,
        OWNER
      ),
    by = "park_id"
  ) |>
  select(
    park_id,
    MA_NAME,
    OWNER,
    all_of(all_amenity_fields)
  ) |>
  arrange(park_id)

writexl::write_xlsx(
  x = list(amenities = amenities),
  path = amenity_output
)

# =============================================================================
# SUMMARY
# =============================================================================

cat(
  "\nMigration complete\n",
  "Legacy source rows: ", nrow(legacy), "\n",
  "Empty geometry rows sent to review: ", nrow(empty_geometry_review), "\n",
  "Master boundary records: ", nrow(boundaries), "\n",
  "Master amenity records: ", nrow(amenities), "\n",
  "Duplicate park_id values after migration: ", sum(duplicated(boundaries$park_id)), "\n",
  "\nBoundary output: ", boundary_output, "\n",
  "Amenity output: ", amenity_output, "\n",
  "Crosswalk output: ", crosswalk_output, "\n",
  sep = ""
)
