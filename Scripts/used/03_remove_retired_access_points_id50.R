################################################################################
# 03_remove_retired_access_points_id50.R
# ==============================================================================
# Strive for Access
#
# Purpose
#   Remove access points linked to park_id values retired during the
#   PAD-US federal boundary update (Batch ID 48).
#
# Inputs
#   - access_points_20260724.gpkg
#   - park_id_replacements_20260914.csv
#
# Output
#   - access_points_20260914.gpkg
#
# Note
#   This script ONLY removes access points for retired parks.
#   Missing access points for the updated boundary master should be generated
#   separately with 03d_estimate_missing_access_points.R.
################################################################################


# ==============================================================================
# PACKAGES
# ==============================================================================

library(tidyverse)
library(sf)


# ==============================================================================
# CONFIG
# ==============================================================================

root <- "/Users/ywon3/Library/CloudStorage/Dropbox/03_Strive for Access/Data"

access_path <- file.path(
  root,
  "master",
  "access_points",
  "access_points_20260724.gpkg"
)

replacement_path <- file.path(
  root,
  "master",
  "boundaries",
  "park_id_replacements_20260914.csv"
)

output_path <- file.path(
  root,
  "master",
  "access_points",
  "access_points_20260914.gpkg"
)


# ==============================================================================
# PART 1. READ INPUTS
# ==============================================================================

message("Reading access point master: ", access_path)

access_points <- st_read(
  access_path,
  quiet = TRUE
)

message("Reading replacement tracker: ", replacement_path)

replacement_map <- read_csv(
  replacement_path,
  show_col_types = FALSE
)


# ==============================================================================
# PART 2. VALIDATE INPUTS
# ==============================================================================

if (!"park_id" %in% names(access_points)) {
  stop("Access point master does not contain park_id.")
}

if (!"access_point_id" %in% names(access_points)) {
  stop("Access point master does not contain access_point_id.")
}

if (!"old_park_id" %in% names(replacement_map)) {
  stop("Replacement tracker does not contain old_park_id.")
}

if (any(is.na(access_points$access_point_id) | access_points$access_point_id == "")) {
  stop("Access point master contains missing access_point_id values.")
}

if (any(duplicated(access_points$access_point_id))) {
  stop("Access point master contains duplicated access_point_id values.")
}


# ==============================================================================
# PART 3. REMOVE ACCESS POINTS FOR RETIRED PARKS
# ==============================================================================

retired_ids <- unique(replacement_map$old_park_id)

retired_access_points <- access_points %>%
  filter(park_id %in% retired_ids)

access_points_updated <- access_points %>%
  filter(!park_id %in% retired_ids)


cat(
  "\nPrevious access points: ", nrow(access_points),
  "\nRetired park IDs: ", length(retired_ids),
  "\nAccess points removed: ", nrow(retired_access_points),
  "\nRemaining access points: ", nrow(access_points_updated),
  "\n",
  sep = ""
)


# ==============================================================================
# PART 4. QA / QC
# ==============================================================================

if (any(access_points_updated$park_id %in% retired_ids)) {
  stop("Access points linked to retired park_id values remain in the dataset.")
}

if (any(is.na(access_points_updated$access_point_id) |
        access_points_updated$access_point_id == "")) {
  stop("Updated access point master contains missing access_point_id values.")
}

if (any(duplicated(access_points_updated$access_point_id))) {
  stop("Updated access point master contains duplicated access_point_id values.")
}

expected_rows <- nrow(access_points) - nrow(retired_access_points)

if (nrow(access_points_updated) != expected_rows) {
  stop("Updated access point row count is inconsistent.")
}


# ==============================================================================
# PART 5. WRITE OUTPUT
# ==============================================================================

dir.create(
  dirname(output_path),
  recursive = TRUE,
  showWarnings = FALSE
)

st_write(
  access_points_updated,
  output_path,
  layer = "access_points",
  delete_dsn = TRUE,
  quiet = TRUE
)


# Optional audit table of removed access points
removed_csv <- file.path(
  dirname(output_path),
  "retired_access_points_20260914.csv"
)

retired_access_points %>%
  st_drop_geometry() %>%
  write_csv(removed_csv)


# ==============================================================================
# SUMMARY
# ==============================================================================

message("Updated Access Point Dataset written: ", output_path)
message("Removed access point audit written: ", removed_csv)
message("Previous access points: ", nrow(access_points))
message("Access points removed: ", nrow(retired_access_points))
message("Remaining access points: ", nrow(access_points_updated))


