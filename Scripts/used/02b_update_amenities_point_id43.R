# =============================================================================
# 02b_update_amenities_point.R
# -----------------------------------------------------------------------------
# Strive for Access (SFA) - Park Amenity Dataset pipeline
#
# Purpose:
#   Ingest the USFS Recreation Area Activities point layer, match its points to
#   master park boundaries, and update the Master Park Amenity Dataset.
#
# Flow (see SFA data flow diagram, Section 2: Park Amenity Dataset):
#   1) Data sources      : USFS Recreation Area Activities (MapServer, points)
#   2) Process amenities : translate activity names (this script)
#   3) Link to parks     : point in polygon match to park_id
#   4) Output            : amenities/amenities_YYYYMMDD.xlsx
#
# Source structure
#   The layer is long: one row per recreation area and activity pair. The point
#   is the marker for the whole recreation area rather than the location of the
#   individual amenity, so rows of one recareaid share coordinates. PART 4
#   reports any area where that is not the case.
#
# Update rule
#   The source records presence only, so a missing activity is not evidence of
#   absence. Only a Yes is written, into cells that are empty or No. Nothing is
#   ever overwritten.
#
# Coverage note
#   The bounding box is a rectangle around North Carolina, so the download also
#   contains recreation areas in adjacent states. They simply fail to match any
#   master park. PART 4 breaks the match status down by national forest so that
#   out of state areas can be told apart from North Carolina areas that should
#   have matched but did not.
# =============================================================================

# --- Packages ----------------------------------------------------------------

library(arcgislayers)
library(tidyverse)
library(sf)
library(readxl)
library(writexl)


# =============================================================================
# CONFIG (check paths, then run)
# =============================================================================

root <- "/Users/ywon3/Library/CloudStorage/Dropbox/03_Strive for Access/Data"

# Input and output files. Update these three lines before each run. Adding a
# _1, _2 suffix keeps repeated runs on the same day from overwriting.
boundary_path  <- file.path(root, "master", "boundaries", "boundaries_20260721.gpkg")
amenities_path <- file.path(root, "master", "amenities", "amenities_20260723_2.xlsx")
output_path    <- file.path(root, "master", "amenities", "amenities_20260723_3.xlsx")

new_url <- "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_RecreationAreaActivities_01/MapServer/0"

page_size         <- 1000    # MapServer paging size
crs_projected     <- 32119   # NAD83 North Carolina, meters
clip_to_study     <- TRUE    # TRUE pulls only the boundary bounding box
aoi_buffer_m      <- 2000    # bounding box padding in meters
match_tolerance_m <- 0       # 0 requires the point inside a park, above 0 allows a buffer
add_new_columns   <- TRUE    # TRUE adds master columns that do not exist yet
print_rows        <- 30      # console preview length


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


# =============================================================================
# PART 2: LOAD DATA
# =============================================================================

message("Reading master boundaries: ", boundary_path)
boundaries <- st_read(boundary_path, quiet = TRUE) |>
  st_transform(crs_projected) |>
  st_make_valid()

message("Reading amenity table: ", amenities_path)
amenities <- read_amenity_table(amenities_path)

stopifnot("park_id" %in% names(boundaries))
stopifnot("park_id" %in% names(amenities))
stopifnot(!any(duplicated(amenities$park_id)))

# The layer is national, so it is clipped to the padded boundary bounding box
# on the server side unless clip_to_study is FALSE. The box is padded in the
# projected CRS, which avoids buffering in degrees.
message("Opening point source: ", new_url)
new_layer <- arc_open(new_url)

bb <- st_bbox(boundaries)
bb[c("xmin", "ymin")] <- bb[c("xmin", "ymin")] - aoi_buffer_m
bb[c("xmax", "ymax")] <- bb[c("xmax", "ymax")] + aoi_buffer_m
aoi <- st_as_sfc(bb) |> st_transform(4326)

new <- if (clip_to_study) {
  arc_select(new_layer, filter_geom = aoi, page_size = page_size)
} else {
  arc_select(new_layer, page_size = page_size)
}

if (is.na(st_crs(new))) new <- st_set_crs(new, 4326)
new <- new |> st_transform(crs_projected) |> mutate(new_row = row_number())

stopifnot(inherits(new, "sf"), nrow(new) > 0)
stopifnot(all(c("recareaid", "recareaname", "activityname") %in% names(new)))

new_attr <- st_drop_geometry(new) |> as_tibble()

cat("\nMaster boundaries:  ", nrow(boundaries),
    "\nAmenity records:    ", nrow(amenities),
    "\nSource rows:        ", nrow(new),
    "\nRecreation areas:   ", n_distinct(new_attr$recareaid),
    "\nDistinct activities:", n_distinct(new_attr$activityname), "\n")


# =============================================================================
# PART 3: FIELD MAPPING
# =============================================================================

# --- 3.1 USFS activity to master field mapping -------------------------------
# Keys are values of activityname, not parentactivityname, and they must match
# the service vocabulary exactly. Section 3.2 lists every activity in the
# download and flags the ones this table does not cover, which is the check to
# run whenever the service or the study area changes.
# target: existing = column already in the master schema
#         new      = column created by this script when add_new_columns is TRUE

activity_map <- tribble(
  ~activity_name,             ~master_field,      ~target,
  
  # Camping
  "Campground Camping",       "Tent_camping",     "existing",
  "Group Camping",            "Tent_camping",     "existing",
  "Dispersed Camping",        "PrimitiveCamp",    "existing",
  "RV Camping",               "RV_camping",       "existing",
  "Cabin Rentals",            "Cabins",           "existing",
  "Horse Camping",            "Equestrian",       "existing",
  
  # Water
  "Boating - Non-Motorized",  "BluewayPaddle",    "existing",
  "Boating - Motorized",      "BoatRamp",         "existing",
  "Swimming",                 "SwimLake",         "existing",
  
  # Fishing
  "River and Stream Fishing", "Fishing",          "new",
  "Lake and Pond Fishing",    "Fishing",          "new",
  "Salt Water Fishing",       "Fishing",          "new",
  
  # Trails
  "Day Hiking",               "Trails",           "new",
  "Backpacking",              "Trails",           "new",
  "Mountain Biking",          "MountainBike",     "existing",
  "Horse Riding",             "EquestrianTrail",  "existing",
  
  # Other facilities
  "Group Picnicking",         "PicnicShelter",    "existing",
  "Target Shooting",          "ShootingRange",    "existing",
  "Disc Golf",                "DiscGolf",         "existing"
  
  # Deliberately unmapped, no master counterpart:
  #   Picnicking, Viewing Scenery, Viewing Wildlife, Viewing Plants,
  #   Scenic Driving, Interpretive Areas, Visitor Centers, Visitor Programs,
  #   Big Game Hunting, Small Game Hunting, Game Bird/Waterfowl,
  #   OHV Trail Riding, OHV Camping, Road Cycling, Tubing, Waterskiing,
  #   Rock Climbing (natural rock, not the ClimbingWall facility)
)

# --- 3.2 Activity inventory --------------------------------------------------
# Review the unmapped rows and extend the table in 3.1 as needed.

activity_inventory <- new_attr |>
  count(parentactivityname, activityname, name = "n_rows", sort = TRUE) |>
  mutate(mapped = activityname %in% activity_map$activity_name)

cat("\nActivities present in the download:\n")
print(activity_inventory, n = Inf)

cat("\nUnmapped activities (", sum(!activity_inventory$mapped), " of ",
    nrow(activity_inventory), ", ",
    sum(activity_inventory$n_rows[!activity_inventory$mapped]), " rows):\n", sep = "")
print(activity_inventory |> filter(!mapped) |> select(-mapped), n = Inf)

# --- 3.3 Validate the mapping and add missing columns ------------------------

if (!add_new_columns) activity_map <- filter(activity_map, target == "existing")

mapping_problem <- activity_map |>
  filter(target == "existing", !master_field %in% names(amenities))

if (nrow(mapping_problem) > 0) {
  print(mapping_problem)
  stop("One or more mapped master columns are missing from the amenity table.")
}

# A mapped activity that never appears in the download is a likely typo, since
# inner_join would drop it silently.
absent_keys <- setdiff(activity_map$activity_name, new_attr$activityname)
if (length(absent_keys) > 0) {
  warning("Mapped activity names not present in the download: ",
          paste(absent_keys, collapse = ", "))
}

added_columns <- setdiff(activity_map$master_field, names(amenities))
for (col in added_columns) amenities[[col]] <- NA_character_
if (length(added_columns) > 0) {
  message("Columns added to the amenity table: ", paste(added_columns, collapse = ", "))
}


# =============================================================================
# PART 4: MATCH SOURCE POINTS TO PARKS
# =============================================================================
# Each row is matched on its own point. Rows of one recreation area share a
# marker, so a matched area contributes all of its activities, but the rule
# stays at the point level. The count below is the only case where the two
# readings could diverge.

multi_point_areas <- new_attr |>
  group_by(recareaid) |>
  summarise(n_points = n_distinct(paste(longitude, latitude)), .groups = "drop") |>
  filter(n_points > 1)

cat("\nRecreation areas with rows at more than one location:", nrow(multi_point_areas), "\n")

hits <- if (match_tolerance_m > 0) {
  st_is_within_distance(new, boundaries, dist = match_tolerance_m)
} else {
  st_intersects(new, boundaries)
}

matches <- tibble(
  new_row  = rep(seq_along(hits), lengths(hits)),
  park_row = unlist(hits)
) |>
  mutate(park_id = boundaries$park_id[park_row])

rec_area_status <- new_attr |>
  select(new_row, recareaid, recareaname, forestname) |>
  left_join(count(matches, new_row, name = "n_parks"), by = "new_row") |>
  mutate(n_parks = replace_na(n_parks, 0L)) |>
  group_by(recareaid, recareaname, forestname) |>
  summarise(n_parks = max(n_parks), .groups = "drop") |>
  mutate(match_status = case_when(
    n_parks == 0 ~ "no match",
    n_parks == 1 ~ "single match",
    TRUE ~ "multiple matches"
  ))

cat("\nRecreation areas by match status:\n")
print(count(rec_area_status, match_status))

# Out of state forests are expected to miss. A North Carolina forest with a
# high no match count points to a gap in the master boundaries instead.
cat("\nMatch status by national forest:\n")
print(
  rec_area_status |>
    count(forestname, match_status) |>
    pivot_wider(names_from = match_status, values_from = n, values_fill = 0),
  n = Inf
)

cat("\nMaster parks receiving at least one point:",
    n_distinct(matches$park_id), "of", nrow(boundaries), "\n")


# =============================================================================
# PART 5: TRANSLATE ACTIVITIES AND UPDATE THE AMENITY TABLE
# =============================================================================

park_flags <- matches |>
  left_join(select(new_attr, new_row, activityname), by = "new_row") |>
  inner_join(activity_map, by = c("activityname" = "activity_name")) |>
  distinct(park_id, master_field)

update_wide <- park_flags |>
  mutate(value = "Yes") |>
  pivot_wider(names_from = master_field, values_from = value)

cat("Parks receiving at least one mapped activity:", nrow(update_wide), "\n")

amenities_updated <- amenities |>
  left_join(update_wide, by = "park_id", suffix = c("", ".src"))

changelog <- list()

for (fld in unique(activity_map$master_field)) {
  src_col <- paste0(fld, ".src")
  if (!src_col %in% names(amenities_updated)) next
  
  current  <- as.character(amenities_updated[[fld]])
  incoming <- amenities_updated[[src_col]]
  
  idx <- which(!is.na(incoming) & (is.na(current) | current != incoming))
  
  if (length(idx) > 0) {
    changelog[[fld]] <- tibble(
      park_id      = amenities_updated$park_id[idx],
      MA_NAME      = as.character(amenities_updated$MA_NAME[idx]),
      master_field = fld,
      old_value    = current[idx],
      new_value    = incoming[idx]
    )
    current[idx] <- incoming[idx]
    amenities_updated[[fld]] <- current
  }
  
  amenities_updated[[src_col]] <- NULL
}

changelog <- bind_rows(changelog)


# =============================================================================
# PART 6: REVIEW RESULTS (console only)
# =============================================================================

cat("\nAmenity cells updated:", nrow(changelog), "\n")

if (nrow(changelog) > 0) {
  cat("\nUpdates by column:\n")
  print(count(changelog, master_field, sort = TRUE), n = Inf)
  
  cat("\nFirst", min(print_rows, nrow(changelog)), "changed cells (see changelog for all):\n")
  print(head(changelog, print_rows))
}

unmatched <- rec_area_status |>
  filter(match_status == "no match") |>
  select(recareaid, recareaname, forestname)

if (nrow(unmatched) > 0) {
  cat("\nRecreation areas outside every master park (", nrow(unmatched),
      " areas, see the object unmatched for the full list):\n", sep = "")
  print(head(unmatched, print_rows))
}


# =============================================================================
# PART 7: WRITE VERSIONED OUTPUT
# =============================================================================

# Sanity checks before writing
stopifnot(!any(is.na(amenities_updated$park_id)))
stopifnot(!any(duplicated(amenities_updated$park_id)))
stopifnot(nrow(amenities_updated) == nrow(amenities))
stopifnot(!file.exists(output_path))

write_xlsx(amenities_updated, output_path)

message("Master Park Amenity Dataset written: ", output_path)
message("Parks in table: ", nrow(amenities_updated),
        " (", nrow(update_wide), " parks updated from USFS, ",
        nrow(changelog), " cells changed)")