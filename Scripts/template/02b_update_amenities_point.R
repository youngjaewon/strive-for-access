# =============================================================================
# 02b_update_amenities_point.R
# -----------------------------------------------------------------------------
# Strive for Access (SFA) - Park Amenity Dataset pipeline
#
# Purpose:
#   Ingest an external point based amenity source, spatially match its points
#   to master park boundaries, and update the corresponding amenity fields
#   (NA or No -> Yes) in the Master Park Amenity Dataset.
#
# Flow (see SFA data flow diagram, Section 2: Park Amenity Dataset):
#   1) Data sources        : external point based amenity datasets
#   2) Process amenities   : standardize amenity fields (this script)
#   3) Link to parks       : match records to park_id
#   4) Output              : Master Park Amenity Dataset (primary key: park_id)
#                            -> amenities/amenities_YYYYMMDD.csv
#
# Usage:
#   Edit the CONFIG section for each new amenity source, then run the whole
#   script. The example below is configured for the Parks in Wake County
#   point dataset, where each amenity is stored as its own Yes/No column.
# =============================================================================

# --- Packages ----------------------------------------------------------------

library(tidyverse)
library(sf)
library(tmap)


# =============================================================================
# CONFIG (edit this section for each new amenity source)
# =============================================================================

# Paths
root <- "/Volumes/Strive4Access/Data"

boundary_path  <- file.path(root, "boundaries/boundaries_20251014.gpkg")   # master park boundaries (input)
amenities_path <- file.path(root, "amenities/amenities_20251014.csv")      # current amenity table (input)
new_path       <- file.path(root, "PilotArea/Wake/Parks_in_Wake_County")   # new amenity source (input)

# Versioned output: root/amenities/amenities_YYYYMMDD.csv
run_date    <- Sys.Date()                       # or as.Date("2025-03-18")
output_path <- file.path(root, "amenities",
                         paste0("amenities_", format(run_date, "%Y%m%d"), ".csv"))

# Amenity mapping: Yes/No column names in the new source -> amenity column
# names in the master table
amenity_mapping <- c(
  "SKATEPARK"         = "SkatePark",
  "BMXTRACK"          = "PumpTrack",
  "CAROUSEL"          = "Carousel",
  "AMUSEMENTTRAIN"    = "MiniTrain",
  "DISCGOLF"          = "DiscGolf",
  "OUTDOORBASKETBALL" = "BasketballCourt",
  "MULTIPURPOSEFIELD" = "MultipurposeCourt",
  "TENNIS COURT"      = "TennisCourt",
  "SANDVOLLEYBALL"    = "VolleyballSand",
  "TRACK"             = "RunningTrack",
  "EQUESTRIAN"        = "Equestrian",
  "CAMPING"           = "Tent_camping",
  "FISHING"           = "FishSaltOnshore",
  "POOL"              = "SwimPool",
  "PLAYGROUND"        = "Playground",
  "THEATER"           = "Amphitheater",
  "DOGPARK"           = "DogPark",
  "OPEN SHELTER"      = "PicnicShelter",
  "BIKING"            = "MountainBike"
)

# Spatial matching: a point is assigned to a park when it falls within this
# distance (meters) of the park boundary
match_dist <- 15

# Analysis settings
crs_projected <- 32633   # projected CRS for spatial matching

# Interactive visual QC map (set FALSE for non-interactive runs)
run_visual_check <- TRUE


# =============================================================================
# PART 1: LOAD DATA & STANDARDIZE GEOMETRY
# =============================================================================

message("Reading master boundaries: ", boundary_path)
boundaries <- st_read(boundary_path, quiet = TRUE) %>%
  st_transform(crs = crs_projected) %>%
  st_make_valid()

message("Reading amenity table: ", amenities_path)
amenities <- read_csv(amenities_path, show_col_types = FALSE)

message("Reading new amenity source: ", new_path)
new <- st_read(new_path, quiet = TRUE) %>%
  st_transform(crs = crs_projected)

stopifnot("park_id" %in% names(boundaries))
stopifnot("park_id" %in% names(amenities))
stopifnot(all(unname(amenity_mapping) %in% names(amenities)))

# Warn about mapped source columns missing from the new dataset
missing_src_cols <- setdiff(names(amenity_mapping), names(new))
if (length(missing_src_cols) > 0) {
  warning("Source columns not found in new dataset (skipped): ",
          paste(missing_src_cols, collapse = ", "))
  amenity_mapping <- amenity_mapping[setdiff(names(amenity_mapping), missing_src_cols)]
}


# =============================================================================
# PART 2: MATCH DIAGNOSTICS & VISUAL QC
# =============================================================================

# For each new point, count master boundaries within the match distance
within_list <- st_is_within_distance(new, boundaries, dist = match_dist)
new$within_count <- lengths(within_list)

cat("Parks matched per point (0 = unmatched):\n")
print(table(new$within_count))

if (run_visual_check) {
  tmap_mode("view")
  print(
    tm_shape(boundaries) +
      tm_polygons(col = "brown", border.col = "white", alpha = 0.5) +
      tm_shape(new) +
      tm_dots("within_count",
              palette = c("blue", "green", "red"),
              title = "Within Count") +
      tm_layout(legend.outside = TRUE)
  )
}


# =============================================================================
# PART 3: UPDATE AMENITY FIELDS (NA or No -> Yes)
# =============================================================================

amenities_updated <- amenities
updated_count <- 0

# Add a row index to boundaries for joining back to park_id
boundaries$boundary_index <- seq_len(nrow(boundaries))

for (src_col in names(amenity_mapping)) {
  
  master_col <- amenity_mapping[[src_col]]
  
  # Subset new points where this amenity is present
  new_points <- new[!is.na(new[[src_col]]) & new[[src_col]] == "Yes", ]
  if (nrow(new_points) == 0) next
  
  # Find master boundaries within the match distance of any of these points
  join_result <- st_join(boundaries, new_points,
                         join = st_is_within_distance, dist = match_dist,
                         left = FALSE)
  if (nrow(join_result) == 0) next
  
  # park_ids of matched boundaries
  matched_park_ids <- boundaries$park_id[unique(join_result$boundary_index)]
  
  # Update only rows where the current value is NA or No
  row_idx <- which(
    amenities_updated$park_id %in% matched_park_ids &
      (is.na(amenities_updated[[master_col]]) |
         amenities_updated[[master_col]] == "No")
  )
  
  if (length(row_idx) > 0) {
    amenities_updated[[master_col]][row_idx] <- "Yes"
    updated_count <- updated_count + length(row_idx)
    message(sprintf("Amenity '%s': updated %d parks in column '%s'",
                    src_col, length(row_idx), master_col))
  }
}

cat("Total amenity cells updated from NA/No to Yes:", updated_count, "\n")


# =============================================================================
# PART 4: WRITE VERSIONED OUTPUT
# =============================================================================

# Sanity checks before writing
stopifnot(!any(is.na(amenities_updated$park_id)))
stopifnot(!any(duplicated(amenities_updated$park_id)))

if (!dir.exists(dirname(output_path))) dir.create(dirname(output_path), recursive = TRUE)

write_csv(amenities_updated, output_path)

message("Master Park Amenity Dataset written: ", output_path)
message("Parks in table: ", nrow(amenities_updated),
        " (", updated_count, " amenity cells updated)")