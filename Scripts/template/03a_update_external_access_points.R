# =============================================================================
# 03a_update_external_access_points.R
# -----------------------------------------------------------------------------
# Strive for Access (SFA) - Park Access Point Dataset pipeline
#
# Purpose:
#   Ingest an external access point dataset (e.g., county or city park
#   entrance / parking points), standardize it to the master schema, link
#   each point to a park_id, append only genuinely new points, and write a
#   new versioned master access point file.
#
# Flow (see SFA data flow diagram, Section 3: Park Access Point Dataset):
#   1) Data sources        : external access point datasets
#   2) Process inputs      : standardize external points (this script)
#   3) Complete coverage   : 03c / 03d fill parks with no access points
#   4) Output              : Master Park Access Point Dataset
#                            Primary key: access_point_id
#                            Foreign key: park_id
#                            -> access_points/access_points_YYYYMMDD.gpkg
#
# Usage:
#   Edit the CONFIG section for each new source, then run the whole script.
# =============================================================================

# --- Packages ----------------------------------------------------------------

library(tidyverse)
library(sf)
library(tmap)
library(uuid)


# =============================================================================
# CONFIG (edit this section for each new access point source)
# =============================================================================

# Paths
root <- "/Volumes/Strive4Access/Data"

boundary_path <- file.path(root, "boundaries/boundaries_20251014.gpkg")          # master park boundaries (input)
master_path   <- file.path(root, "access_points/access_points_20251014.gpkg")    # current master access points (input)
new_path      <- file.path(root, "SOURCE_FOLDER/AccessPoints.geojson")           # new access point source (input)

# Versioned output: root/access_points/access_points_YYYYMMDD.gpkg
run_date    <- Sys.Date()
output_path <- file.path(root, "access_points",
                         paste0("access_points_", format(run_date, "%Y%m%d"), ".gpkg"))

# Source metadata recorded on appended rows
src_name    <- "SOURCE NAME"          # e.g., "Wake County", "City of Raleigh"
creator     <- "youngjaewon"
create_time <- as.POSIXct(paste(run_date, "12:00:00"))

# Column mapping: names(new dataset) -> master access point schema
# Only map the columns that exist in the new source.
col_map <- c(
  AP_NAME = "NAME"
  # AP_TYPE = "TYPE"   # e.g., entrance, parking, trailhead
)

# Spatial rules
crs_projected <- 32633   # projected CRS for distance calculations
link_dist     <- 100     # max distance (m) from a park boundary to link a point to that park
dedupe_dist   <- 30      # a new point within this distance (m) of an existing
# access point of the same park is treated as a duplicate

# Interactive visual QC map (set FALSE for non-interactive runs)
run_visual_check <- TRUE


# =============================================================================
# PART 1: LOAD DATA & STANDARDIZE GEOMETRY
# =============================================================================

message("Reading master boundaries: ", boundary_path)
boundaries <- st_read(boundary_path, quiet = TRUE) %>%
  st_transform(crs = crs_projected) %>%
  st_make_valid()

message("Reading master access points: ", master_path)
master <- st_read(master_path, quiet = TRUE) %>%
  st_transform(crs = crs_projected)

message("Reading new access point source: ", new_path)
new <- st_read(new_path, quiet = TRUE) %>%
  st_transform(crs = crs_projected) %>%
  st_cast("POINT")   # explode multipoints if present

stopifnot("park_id" %in% names(boundaries))
stopifnot(all(c("access_point_id", "park_id") %in% names(master)))


# =============================================================================
# PART 2: LINK NEW POINTS TO PARKS
# =============================================================================

# Assign each new point to the nearest park boundary within link_dist.
# Points farther than link_dist from any park are dropped for review.
nearest_idx <- st_nearest_feature(new, boundaries)
nearest_dist <- st_distance(new, boundaries[nearest_idx, ], by_element = TRUE)

new <- new %>%
  mutate(
    park_id   = boundaries$park_id[nearest_idx],
    park_dist = as.numeric(nearest_dist)
  )

new_linked  <- new %>% filter(park_dist <= link_dist)
new_dropped <- new %>% filter(park_dist > link_dist)

message(nrow(new_linked), " of ", nrow(new),
        " points linked to a park within ", link_dist, "m (",
        nrow(new_dropped), " dropped for review).")


# =============================================================================
# PART 3: REMOVE DUPLICATES AGAINST EXISTING MASTER POINTS
# =============================================================================

# A new point is a duplicate if an existing access point of the same park
# lies within dedupe_dist.
dup_flags <- map_lgl(seq_len(nrow(new_linked)), function(i) {
  same_park <- master %>% filter(park_id == new_linked$park_id[i])
  if (nrow(same_park) == 0) return(FALSE)
  min_d <- min(as.numeric(st_distance(new_linked[i, ], same_park)))
  min_d <= dedupe_dist
})

new_unique <- new_linked %>% filter(!dup_flags)

message(sum(dup_flags), " duplicates removed (", dedupe_dist, "m rule); ",
        nrow(new_unique), " new access points to append.")

# --- Visual QC ---------------------------------------------------------------

if (run_visual_check) {
  tmap_mode("view")
  print(
    tm_shape(boundaries) +
      tm_polygons(col = "lightblue", alpha = 0.4, border.col = "blue") +
      tm_shape(master) +
      tm_dots(col = "gray40") +
      tm_shape(new_unique) +
      tm_dots(col = "red") +
      tm_shape(new_dropped) +
      tm_dots(col = "orange")
  )
}


# =============================================================================
# PART 4: STANDARDIZE SCHEMA & MAINTAIN IDs
# =============================================================================

new_selected <- new_unique %>%
  rename(any_of(col_map)) %>%
  select(any_of(names(col_map)), park_id) %>%
  mutate(
    access_point_id = UUIDgenerate(n = n()),   # new UUIDs only for new points
    GIS_SRC         = src_name,
    Creator         = creator,
    CreationDate    = create_time
  )


# =============================================================================
# PART 5: COMBINE & WRITE VERSIONED OUTPUT
# =============================================================================

master_updated <- bind_rows(master, new_selected)

# Sanity checks before writing
stopifnot(!any(is.na(master_updated$access_point_id)))
stopifnot(!any(duplicated(master_updated$access_point_id)))
stopifnot(!any(is.na(master_updated$park_id)))

if (!dir.exists(dirname(output_path))) dir.create(dirname(output_path), recursive = TRUE)

st_write(master_updated, output_path, delete_dsn = TRUE, quiet = TRUE)

message("Master Park Access Point Dataset written: ", output_path)
message("Total access points: ", nrow(master_updated),
        " (", nrow(new_selected), " appended from ", src_name, ")")