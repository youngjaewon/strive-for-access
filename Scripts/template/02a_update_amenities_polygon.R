# =============================================================================
# 02a_update_amenities_polygon.R
# -----------------------------------------------------------------------------
# Strive for Access (SFA) - Park Amenity Dataset pipeline
#
# Purpose:
#   Read the master boundaries, the master amenity table, and the PTRC polygon
#   park source. Give every park_id in the boundaries an amenity row, match the
#   PTRC polygons to master parks by area overlap, translate the PTRC Use_ flags
#   into master amenity columns, and write a dated amenity file.
#
# Flow (see SFA data flow diagram, Section 2: Park Amenity Dataset):
#   1) Data sources      : PTRC park polygons (FeatureServer)
#   2) Process amenities : translate Use_ flags (this script)
#   3) Link to parks     : area overlap match to park_id
#   4) Output            : amenities/amenities_YYYYMMDD.xlsx
#
# Update rules
#   The PTRC source is treated as authoritative for the amenities it covers.
#   A source Y writes Yes and a source N writes No, replacing whatever the
#   master holds. A missing source value is treated as not reviewed and leaves
#   the master value untouched. When several polygons match one park, a single
#   Y wins.
#
# Review objects left in the environment: changelog, match_report, coverage.
# The amenity table is the only file written.
# =============================================================================

# --- Packages ----------------------------------------------------------------

library(tidyverse)
library(sf)
library(readxl)
library(writexl)
library(tmap)


# =============================================================================
# CONFIG (check paths, then run)
# =============================================================================

root <- "/Users/ywon3/Library/CloudStorage/Dropbox/03_Strive for Access/Data"

boundaries_dir <- file.path(root, "master", "boundaries")
amenities_dir  <- file.path(root, "master", "amenities")

# Set an explicit path, or leave NULL to take the most recent dated file
boundary_path  <- NULL
amenities_path <- NULL

new_url <- paste0(
  "https://maps.ptrc.org/arcgis/rest/services/",
  "Recreation/Parks/FeatureServer/0/query",
  "?where=1%3D1&outFields=%2A&returnGeometry=true&outSR=4326&f=geojson"
)

run_date    <- Sys.Date()
output_path <- file.path(amenities_dir, paste0("amenities_", format(run_date, "%Y%m%d"), ".xlsx"))

crs_projected     <- 32119   # NAD83 North Carolina, meters
min_overlap_ratio <- 0.50    # share of either polygon that must be covered
add_new_columns   <- TRUE    # TRUE adds master columns that do not exist yet
print_rows        <- 25      # console preview length for the change log
run_visual_check  <- TRUE


# =============================================================================
# PART 1: HELPERS
# =============================================================================

latest_file <- function(dir, pattern, exclude = NULL) {
  f <- list.files(dir, pattern = pattern, full.names = TRUE)
  f <- f[!str_detect(basename(f), "^~\\$")]
  if (!is.null(exclude)) f <- f[!basename(f) %in% basename(exclude)]
  if (length(f) == 0) stop("No file matching ", pattern, " in ", dir)
  f[order(basename(f), decreasing = TRUE)][1]
}

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

# Y, Yes, TRUE, 1 -> Y. N, No, FALSE, 0 -> N. Anything else -> NA.
normalize_flag <- function(x) {
  x <- str_to_lower(str_squish(as.character(x)))
  case_when(
    x %in% c("y", "yes", "true", "t", "1") ~ "Y",
    x %in% c("n", "no", "false", "f", "0") ~ "N",
    TRUE ~ NA_character_
  )
}

standardize_geometry_name <- function(x) {
  g <- attr(x, "sf_column")
  if (is.null(g)) stop("The object has no active sf geometry column.")
  if (g != "geometry") { names(x)[names(x) == g] <- "geometry"; attr(x, "sf_column") <- "geometry" }
  x
}


# =============================================================================
# PART 2: LOAD DATA
# =============================================================================

if (is.null(boundary_path)) {
  boundary_path <- latest_file(boundaries_dir, "^boundaries_\\d{8}\\.gpkg$")
}

if (is.null(amenities_path)) {
  amenities_path <- latest_file(amenities_dir, "^amenities_\\d{8}\\.(xlsx|csv)$", exclude = output_path)
}

message("Reading master boundaries: ", boundary_path)
boundaries <- st_read(boundary_path, quiet = TRUE) |>
  standardize_geometry_name() |>
  st_transform(crs_projected) |>
  st_make_valid()

message("Reading amenity table: ", amenities_path)
amenities <- read_amenity_table(amenities_path)

message("Reading PTRC polygon source")
new <- st_read(new_url, quiet = TRUE) |> standardize_geometry_name()
if (is.na(st_crs(new))) new <- st_set_crs(new, 4326)
new <- new |>
  st_transform(crs_projected) |>
  st_make_valid() |>
  st_collection_extract("POLYGON", warn = FALSE) |>
  st_cast("MULTIPOLYGON", warn = FALSE)

sf::sf_use_s2(FALSE)

stopifnot("park_id" %in% names(boundaries))
stopifnot("park_id" %in% names(amenities))
stopifnot(nrow(new) > 0)
stopifnot(!any(duplicated(boundaries$park_id)))
stopifnot(!any(duplicated(amenities$park_id)))

cat("\nMaster boundaries:", nrow(boundaries),
    "\nAmenity records: ", nrow(amenities),
    "\nPTRC polygons:   ", nrow(new), "\n")


# =============================================================================
# PART 3: FIELD MAPPING
# =============================================================================

# --- 3.1 PTRC to master field mapping ----------------------------------------
# Edit this table when fields need to be added or changed.
# target: existing = column already in the master schema
#         new      = column created by this script when add_new_columns is TRUE

amenity_map <- tribble(
  ~source_field,    ~master_field,      ~value_type, ~target,
  
  # Fields with a direct master counterpart
  "Use_Shelter",    "PicnicShelter",    "yes_no",    "existing",
  "Use_BallField",  "DiamondField",     "yes_no",    "existing",
  "Use_Playground", "Playground",       "yes_no",    "existing",
  "Use_Pool",       "SwimPool",         "yes_no",    "existing",
  "Use_DiscGolf",   "DiscGolf",         "yes_no",    "existing",
  "Use_DogPark",    "DogPark",          "yes_no",    "existing",
  "Use_Basketball", "BasketballCourt",  "yes_no",    "existing",
  "Use_Tennis",     "TennisCourt",      "yes_no",    "existing",
  "Use_SplashPad",  "Sprayground",      "yes_no",    "existing",
  "Use_Volleyball", "VolleyballOther",  "yes_no",    "existing",
  
  # Fields with no master counterpart, added as new columns
  "Use_Trails",     "Trails",           "yes_no",    "new",
  "Use_Fishing",    "Fishing",          "yes_no",    "new",
  "Use_Soccer",     "SoccerField",      "yes_no",    "new",
  "Use_Bathrooms",  "Restrooms",        "yes_no",    "new",
  "Use_RecCenter",  "RecCenter",        "yes_no",    "new"
)

# --- 3.2 Validate mapped fields ----------------------------------------------

if (!add_new_columns) amenity_map <- filter(amenity_map, target == "existing")

mapping_problem <- amenity_map |>
  mutate(
    source_exists = source_field %in% names(new),
    master_exists = master_field %in% names(amenities),
    expected      = target == "existing"
  ) |>
  filter(!source_exists | (expected & !master_exists))

if (nrow(mapping_problem) > 0) {
  print(mapping_problem)
  stop("One or more mapped fields are missing from the PTRC source or the amenity table.")
}

unmapped_source <- setdiff(names(new)[str_starts(names(new), "Use_")], amenity_map$source_field)
if (length(unmapped_source) > 0) {
  message("Source Use_ fields with no mapping: ", paste(unmapped_source, collapse = ", "))
}

# --- 3.3 Add master columns that do not exist yet ----------------------------

added_columns <- setdiff(amenity_map$master_field, names(amenities))
for (col in added_columns) amenities[[col]] <- NA_character_
if (length(added_columns) > 0) {
  message("Columns added to the amenity table: ", paste(added_columns, collapse = ", "))
}


# =============================================================================
# PART 4: RECONCILE AMENITY ROWS WITH THE BOUNDARIES
# =============================================================================
# Script 01 appends parks to the boundaries without adding amenity rows.
# Those rows are created here so the two masters stay aligned on park_id.

carry_fields <- intersect(c("park_id", "MA_NAME", "OWNER"), names(amenities))

missing_ids <- setdiff(boundaries$park_id, amenities$park_id)
orphan_ids  <- setdiff(amenities$park_id, boundaries$park_id)

# Guard: a large missing count means the park_id keys do not line up at all
# (wrong file, regenerated ids), not genuinely new parks.
if (length(missing_ids) > 0.05 * nrow(boundaries)) {
  stop(
    length(missing_ids), " of ", nrow(boundaries),
    " boundary park_ids are absent from the amenity table. ",
    "The park_id keys likely do not match. Check with: ",
    "length(intersect(boundaries$park_id, amenities$park_id))"
  )
}

if (length(missing_ids) > 0) {
  rows_to_add <- boundaries |>
    st_drop_geometry() |>
    as_tibble() |>
    filter(park_id %in% missing_ids) |>
    select(any_of(carry_fields)) |>
    mutate(across(everything(), as.character))
  
  amenities <- bind_rows(amenities, rows_to_add)
  message(length(missing_ids), " amenity rows added for parks found only in the boundary table.")
}

if (length(orphan_ids) > 0) {
  warning(length(orphan_ids), " amenity rows carry a park_id that is not in the boundary table.")
}

cat("Amenity records after reconciliation:", nrow(amenities), "\n")


# =============================================================================
# PART 5: MATCH PTRC POLYGONS TO PARKS
# =============================================================================

new <- new |>
  mutate(
    new_row  = row_number(),
    src_key  = as.character(if ("GlobalID" %in% names(new)) GlobalID else OBJECTID),
    new_area = as.numeric(st_area(geometry))
  )

boundaries <- boundaries |>
  mutate(park_row = row_number(), park_area = as.numeric(st_area(geometry)))

hits  <- st_intersects(new, boundaries)
pairs <- tibble(new_row = rep(seq_along(hits), lengths(hits)), park_row = unlist(hits))
stopifnot(nrow(pairs) > 0)

message("Candidate polygon pairs to evaluate: ", nrow(pairs))

g_new  <- st_geometry(new)
g_park <- st_geometry(boundaries)

pairs$inter_area <- map2_dbl(pairs$new_row, pairs$park_row, \(i, j) {
  sum(as.numeric(st_area(suppressWarnings(st_intersection(g_new[i], g_park[j])))))
})

matches <- pairs |>
  mutate(
    ratio_new  = inter_area / new$new_area[new_row],
    ratio_park = inter_area / boundaries$park_area[park_row],
    park_id    = boundaries$park_id[park_row],
    src_key    = new$src_key[new_row]
  ) |>
  filter(ratio_new >= min_overlap_ratio | ratio_park >= min_overlap_ratio)

unmatched_rows <- setdiff(seq_len(nrow(new)), unique(matches$new_row))

cat("\nPTRC polygons matched:", nrow(new) - length(unmatched_rows), "of", nrow(new),
    "\nPolygon to park links:", nrow(matches), "\n")


# =============================================================================
# PART 6: TRANSLATE FLAGS AND UPDATE THE AMENITY TABLE
# =============================================================================

# --- 6.1 Summarize source flags by park --------------------------------------
# A missing source value is dropped here, so it can never overwrite the master.
# Across multiple polygons on the same park, a single Y wins.

park_flags <- matches |>
  select(new_row, park_id) |>
  left_join(
    new |> st_drop_geometry() |> as_tibble() |> select(new_row, all_of(amenity_map$source_field)),
    by = "new_row"
  ) |>
  pivot_longer(all_of(amenity_map$source_field), names_to = "source_field", values_to = "value") |>
  mutate(flag = normalize_flag(value)) |>
  filter(!is.na(flag)) |>
  left_join(select(amenity_map, source_field, master_field), by = "source_field") |>
  group_by(park_id, master_field) |>
  summarise(flag = if_else(any(flag == "Y"), "Y", "N"), .groups = "drop")

update_wide <- park_flags |>
  mutate(value = if_else(flag == "Y", "Yes", "No")) |>
  select(park_id, master_field, value) |>
  pivot_wider(names_from = master_field, values_from = value)

# --- 6.2 Merge into the amenity table ----------------------------------------
# The source is authoritative: its value replaces the master value whenever
# the two disagree. Cells the source does not cover are left untouched.

amenities_updated <- amenities |>
  left_join(update_wide, by = "park_id", suffix = c("", ".src"))

changelog <- list()

for (fld in amenity_map$master_field) {
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
# PART 7: REVIEW RESULTS (console only)
# =============================================================================

cat("\nAmenity cells updated:", nrow(changelog), "\n")

if (nrow(changelog) > 0) {
  cat("\nUpdates by column:\n")
  print(count(changelog, master_field, new_value, sort = TRUE), n = Inf)
  
  # Cells where the source contradicted an existing master value deserve a
  # closer look, in particular Yes to No downgrades.
  downgrades <- changelog |> filter(old_value == "Yes", new_value == "No")
  if (nrow(downgrades) > 0) {
    cat("\nYes to No downgrades (", nrow(downgrades), " cells):\n", sep = "")
    print(head(downgrades, print_rows))
  }
  
  cat("\nFirst", min(print_rows, nrow(changelog)), "changed cells (see changelog for all):\n")
  print(head(changelog, print_rows))
}

coverage <- amenities_updated |>
  summarise(across(all_of(amenity_map$master_field), ~ sum(normalize_flag(.x) == "Y", na.rm = TRUE))) |>
  pivot_longer(everything(), names_to = "master_field", values_to = "n_yes")

cat("\nParks flagged Yes by column after the update:\n")
print(coverage, n = Inf)

# PTRC polygons and their match status, with the free text Description field,
# which sometimes carries hints such as add tennis. Review these manually.
match_report <- new |>
  st_drop_geometry() |>
  as_tibble() |>
  select(new_row, src_key, any_of(c("ParkName", "County", "ManagingAgency", "Description"))) |>
  left_join(
    matches |> group_by(new_row) |> summarise(
      matched_park_ids = paste(park_id, collapse = "; "),
      n_matched_parks  = n(),
      .groups = "drop"
    ),
    by = "new_row"
  ) |>
  mutate(
    n_matched_parks = replace_na(n_matched_parks, 0L),
    match_status = case_when(
      n_matched_parks == 0 ~ "no match",
      n_matched_parks == 1 ~ "single match",
      TRUE ~ "multiple matches"
    )
  )

cat("\nMatch status:\n")
print(count(match_report, match_status))

if (length(unmatched_rows) > 0) {
  cat("\nUnmatched PTRC polygons (review manually):\n")
  print(
    match_report |>
      filter(match_status == "no match") |>
      select(any_of(c("src_key", "ParkName", "County", "ManagingAgency"))),
    n = print_rows
  )
}

if (run_visual_check && length(unmatched_rows) > 0) {
  tmap_mode("view")
  print(
    tm_shape(boundaries) + tm_polygons(fill = "#2F80ED", fill_alpha = 0.4, col = NA) +
      tm_shape(new[unmatched_rows, ]) + tm_polygons(fill = "#E53935", fill_alpha = 0.8, col = NA)
  )
}


# =============================================================================
# PART 8: WRITE VERSIONED OUTPUT
# =============================================================================

# Sanity checks before writing
stopifnot(!any(is.na(amenities_updated$park_id)))
stopifnot(!any(duplicated(amenities_updated$park_id)))
stopifnot(all(boundaries$park_id %in% amenities_updated$park_id))

if (!dir.exists(amenities_dir)) dir.create(amenities_dir, recursive = TRUE)

write_xlsx(amenities_updated, output_path)

message("Master Park Amenity Dataset written: ", output_path)
message("Parks in table: ", nrow(amenities_updated),
        " (", nrow(changelog), " amenity cells updated)")