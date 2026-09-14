################################################################################
# 04_remove_retired_service_areas_id51.R
# ==============================================================================
# Strive for Access
#
# Purpose
#   Remove service areas linked to access points that were retired during
#   the PAD-US federal boundary update.
#
# Inputs
#   - isochrones_10min_20260724.gpkg
#   - retired_access_points_20260914.csv
#
# Output
#   - isochrones_10min_20260914.gpkg
#
# Note
#   This script ONLY removes service areas associated with retired access points.
#   New service areas should be generated later, after missing access points are
#   recreated for the updated boundary master.
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

service_area_path <- file.path(
  root,
  "master",
  "service_areas",
  "isochrones_10min_20260724.gpkg"
)

retired_access_path <- file.path(
  root,
  "master",
  "access_points",
  "retired_access_points_20260914.csv"
)

output_path <- file.path(
  root,
  "master",
  "service_areas",
  "isochrones_10min_20260914.gpkg"
)


# ==============================================================================
# PART 1. READ INPUTS
# ==============================================================================

message("Reading service area master: ", service_area_path)

service_areas <- st_read(
  service_area_path,
  quiet = TRUE
)

message("Reading retired access point audit: ", retired_access_path)

retired_access_points <- read_csv(
  retired_access_path,
  show_col_types = FALSE
)


# ==============================================================================
# PART 2. VALIDATE INPUTS
# ==============================================================================

if (!"service_area_id" %in% names(service_areas)) {
  stop("Service area master does not contain service_area_id.")
}

if (!"access_point_id" %in% names(service_areas)) {
  stop("Service area master does not contain access_point_id.")
}

if (!"park_id" %in% names(service_areas)) {
  stop("Service area master does not contain park_id.")
}

if (!"access_point_id" %in% names(retired_access_points)) {
  stop("Retired access point audit does not contain access_point_id.")
}

if (any(is.na(service_areas$service_area_id) | service_areas$service_area_id == "")) {
  stop("Service area master contains missing service_area_id values.")
}

if (any(duplicated(service_areas$service_area_id))) {
  stop("Service area master contains duplicated service_area_id values.")
}


# ==============================================================================
# PART 3. REMOVE SERVICE AREAS FOR RETIRED ACCESS POINTS
# ==============================================================================

retired_access_ids <- unique(retired_access_points$access_point_id)

retired_service_areas <- service_areas %>%
  filter(access_point_id %in% retired_access_ids)

service_areas_updated <- service_areas %>%
  filter(!access_point_id %in% retired_access_ids)


cat(
  "\nPrevious service areas: ", nrow(service_areas),
  "\nRetired access point IDs: ", length(retired_access_ids),
  "\nService areas removed: ", nrow(retired_service_areas),
  "\nRemaining service areas: ", nrow(service_areas_updated),
  "\n",
  sep = ""
)


# ==============================================================================
# PART 4. QA / QC
# ==============================================================================

if (any(service_areas_updated$access_point_id %in% retired_access_ids)) {
  stop("Service areas linked to retired access points remain in the dataset.")
}

if (any(is.na(service_areas_updated$service_area_id) |
        service_areas_updated$service_area_id == "")) {
  stop("Updated service area master contains missing service_area_id values.")
}

if (any(duplicated(service_areas_updated$service_area_id))) {
  stop("Updated service area master contains duplicated service_area_id values.")
}

expected_rows <- nrow(service_areas) - nrow(retired_service_areas)

if (nrow(service_areas_updated) != expected_rows) {
  stop("Updated service area row count is inconsistent.")
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
  service_areas_updated,
  output_path,
  layer = "service_areas",
  delete_dsn = TRUE,
  quiet = TRUE
)


# Audit table of removed service areas
removed_csv <- file.path(
  dirname(output_path),
  "retired_service_areas_20260914.csv"
)

retired_service_areas %>%
  st_drop_geometry() %>%
  write_csv(removed_csv)


# ==============================================================================
# SUMMARY
# ==============================================================================

message("Updated Service Area Dataset written: ", output_path)
message("Removed service area audit written: ", removed_csv)
message("Previous service areas: ", nrow(service_areas))
message("Service areas removed: ", nrow(retired_service_areas))
message("Remaining service areas: ", nrow(service_areas_updated))

