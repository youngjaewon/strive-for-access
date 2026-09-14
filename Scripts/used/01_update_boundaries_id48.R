################################################################################
# 01_update_park_boundaries.R
# ==============================================================================
# Strive for Access
#
# Purpose
#   Update the Master Park Boundary Dataset using a curated federal recreation
#   layer derived from PAD-US 4.1 (North Carolina).
#
# Workflow
#   1. Build a PAD-US-AR-like federal recreation source from PAD-US 4.1.
#   2. Remove obvious source-level duplicates / nested polygons.
#   3. Identify existing master polygons that are >= 90% covered by a larger
#      federal source polygon ("replacement candidates").
#   4. Temporarily remove replacement candidates and apply the standard
#      5% overlap rule to determine which federal polygons should be appended.
#   5. Confirm retirements only when the corresponding replacement polygon is
#      actually appended.
#   6. Re-run the 5% overlap test against the confirmed retained master.
#   7. Preserve existing park_id values, assign new IDs only to appended parks,
#      and write:
#        - updated boundary master
#        - old park_id -> new park_id replacement tracker
#
# Important
#   The replacement tracker must be used to remove retired park_id values from
#   the Amenities, Access Points, and Drive Time Service Area master datasets.
################################################################################

library(tidyverse)
library(sf)
library(tmap)
library(ids)

# ==============================================================================
# CONFIG
# ==============================================================================

root <- "/Users/ywon3/Library/CloudStorage/Dropbox/03_Strive for Access/Data"

master_path <- file.path(
  root,
  "master",
  "boundaries",
  "boundaries_20260721.gpkg"
)

padus_gdb_path <- file.path(
  root,
  "source",
  "PADUS4_1_State_NC_GDB_KMZ",
  "PADUS4_1_StateNC.gdb"
)

run_date <- Sys.Date()
date_stamp <- format(run_date, "%Y%m%d")

output_dir <- file.path(root, "master", "boundaries")
output_path <- file.path(output_dir, paste0("boundaries_", date_stamp, ".gpkg"))
replacement_path <- file.path(
  output_dir,
  paste0("park_id_replacements_", date_stamp, ".csv")
)

src_name <- "USGS PAD-US 4.1, curated using PAD-US-AR criteria"
creator <- "youngjaewon"
create_time <- as.POSIXct(
  paste(run_date, "12:00:00"),
  tz = "America/New_York"
)

# NAD83 North Carolina, meters
crs_projected <- 32119

# New federal polygon is treated as already represented when >= 5% of its own
# area overlaps the retained master.
overlap_threshold <- 0.05

# Existing master polygon is treated as replaced when >= 90% of its own area is
# covered by a larger federal source polygon.
replacement_threshold <- 0.90

# Within the PAD-US source, remove a smaller polygon when >= 90% of its own area
# is contained in a larger PAD-US polygon.
source_nested_threshold <- 0.90

run_visual_check <- TRUE

# PAD-US-AR-like exceptions / manual QA decisions
padus_exceptions <- c(
  "B. Everett Jordan Dam and Lake"
)

manual_exclusions <- c(
  "Kerr Lake State Recreation Area"
)

# ==============================================================================
# HELPERS
# ==============================================================================

generate_park_ids <- function(n, existing_ids = character()) {
  if (n == 0) return(character())

  new_ids <- character()

  while (length(new_ids) < n) {
    candidates <- ids::random_id(
      n = n - length(new_ids),
      bytes = 6
    ) %>%
      unique()

    candidates <- candidates[
      !candidates %in% existing_ids &
        !candidates %in% new_ids
    ]

    new_ids <- c(new_ids, candidates)
  }

  new_ids
}

standardize_geometry_name <- function(x) {
  geometry_name <- attr(x, "sf_column")

  if (is.null(geometry_name)) {
    stop("The object does not have an active sf geometry column.")
  }

  if (geometry_name != "geometry") {
    names(x)[names(x) == geometry_name] <- "geometry"
    attr(x, "sf_column") <- "geometry"
  }

  x
}

prepare_polygons <- function(x, crs) {
  x %>%
    standardize_geometry_name() %>%
    st_transform(crs) %>%
    st_make_valid() %>%
    st_collection_extract("POLYGON", warn = FALSE) %>%
    st_cast("MULTIPOLYGON", warn = FALSE)
}

blank_to_na <- function(x) {
  x %>%
    as.character() %>%
    str_squish() %>%
    na_if("")
}

standardize_owner_name <- function(x) {
  x <- blank_to_na(x)

  case_when(
    str_to_lower(x) == "mount airy" ~ "Mount Airy",
    TRUE ~ x
  )
}

# Fraction of each source polygon covered by the union of a master layer.
calculate_source_overlap <- function(new, master) {
  if (nrow(master) == 0) {
    return(
      new %>%
        mutate(
          total_overlap = 0,
          overlap_ratio = 0
        )
    )
  }

  master_union <- st_sf(
    geometry = st_union(st_geometry(master)),
    crs = st_crs(master)
  ) %>%
    st_make_valid()

  intersections <- suppressWarnings(
    st_intersection(
      new %>% select(new_id),
      master_union
    )
  ) %>%
    mutate(
      intersect_area = as.numeric(st_area(geometry))
    ) %>%
    st_drop_geometry() %>%
    group_by(new_id) %>%
    summarise(
      total_overlap = sum(intersect_area),
      .groups = "drop"
    )

  new %>%
    left_join(intersections, by = "new_id") %>%
    mutate(
      total_overlap = replace_na(total_overlap, 0),
      overlap_ratio = total_overlap / new_area
    )
}

# ==============================================================================
# PART 1. READ MASTER BOUNDARIES
# ==============================================================================

message("Reading master: ", master_path)

master <- st_read(
  master_path,
  quiet = TRUE
) %>%
  standardize_geometry_name()

if (is.na(st_crs(master))) {
  stop("The master boundary dataset does not have a CRS.")
}

if (!"park_id" %in% names(master)) {
  stop("The master boundary dataset does not contain park_id.")
}

if (any(is.na(master$park_id) | master$park_id == "")) {
  stop("The master boundary dataset contains missing park_id values.")
}

if (any(duplicated(master$park_id))) {
  stop("The master boundary dataset contains duplicated park_id values.")
}

master <- prepare_polygons(master, crs_projected)

if (any(st_is_empty(master))) {
  stop("The master boundary dataset contains empty geometries.")
}

sf::sf_use_s2(FALSE)

# ==============================================================================
# PART 2. BUILD PAD-US 4.1 FEDERAL RECREATION SOURCE
# ==============================================================================

message("Reading PAD-US 4.1 North Carolina geodatabase: ", padus_gdb_path)

fee <- st_read(
  padus_gdb_path,
  layer = "PADUS4_1Fee_State_NC",
  quiet = TRUE
) %>%
  mutate(source_class = "Fee")

ease <- st_read(
  padus_gdb_path,
  layer = "PADUS4_1Easement_State_NC",
  quiet = TRUE
) %>%
  mutate(source_class = "Easement")

desig <- st_read(
  padus_gdb_path,
  layer = "PADUS4_1Designation_State_NC",
  quiet = TRUE
) %>%
  mutate(source_class = "Designation")

common_cols <- Reduce(
  intersect,
  list(names(fee), names(ease), names(desig))
)

pad <- bind_rows(
  fee   %>% select(all_of(common_cols)),
  ease  %>% select(all_of(common_cols)),
  desig %>% select(all_of(common_cols))
)

# PAD-US-AR-like federal curation:
# OA = Open Access; RA = Restricted Access; UK = Unknown Access.
# For UK, retain recreation-relevant federal managers used in PAD-US-AR.
fed_ar <- pad %>%
  filter(Own_Type == "FED") %>%
  filter(
    Pub_Access %in% c("OA", "RA") |
      (Pub_Access == "UK" & Mang_Name %in% c("USFS", "USACE", "TVA")) |
      Unit_Nm %in% padus_exceptions
  ) %>%
  filter(
    !str_detect(Unit_Nm, "Registered Heritage Area"),
    Own_Name != "DOD",
    !Unit_Nm %in% manual_exclusions
  )

# Same-name duplicates: retain the largest polygon.
fed_ar <- fed_ar %>%
  mutate(.area = as.numeric(st_area(.))) %>%
  group_by(Unit_Nm) %>%
  slice_max(.area, n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  select(-.area)

# Remove smaller source polygons that are mostly contained in a larger source
# polygon.
source_x <- fed_ar %>%
  mutate(
    .id = row_number(),
    .area = as.numeric(st_area(.))
  )

source_overlap <- suppressWarnings(
  st_intersection(
    source_x %>% select(.id, .area),
    source_x %>% transmute(.id2 = .id, .area2 = .area)
  )
) %>%
  filter(.id != .id2, .area2 > .area) %>%
  mutate(
    .overlap = as.numeric(st_area(.)) / .area
  ) %>%
  filter(.overlap >= source_nested_threshold)

fed_ar <- source_x %>%
  filter(!.id %in% source_overlap$.id) %>%
  select(-.id, -.area)

# Convert curated PAD-US fields to the SFA source schema.
new <- fed_ar %>%
  standardize_geometry_name() %>%
  transmute(
    MA_NAME = Unit_Nm,
    OWNER = d_Own_Name,
    geometry
  ) %>%
  prepare_polygons(crs_projected) %>%
  mutate(
    new_id = row_number(),
    new_area = as.numeric(st_area(geometry))
  )

if (any(st_is_empty(new))) {
  stop("The curated PAD-US source contains empty geometries.")
}

if (any(!is.finite(new$new_area) | new$new_area <= 0)) {
  stop("The curated PAD-US source contains invalid polygon areas.")
}

message("Curated PAD-US federal polygons: ", nrow(new))

# ==============================================================================
# PART 3. IDENTIFY MASTER POLYGONS REPLACED BY LARGER FEDERAL POLYGONS
# ==============================================================================

master_x <- master %>%
  mutate(
    master_row = row_number(),
    master_area = as.numeric(st_area(geometry))
  )

replacement_pairs <- suppressWarnings(
  st_intersection(
    master_x %>%
      select(
        master_row,
        old_park_id = park_id,
        old_name = MA_NAME,
        master_area
      ),
    new %>%
      select(
        new_id,
        new_name = MA_NAME,
        new_area
      )
  )
) %>%
  mutate(
    intersect_area = as.numeric(st_area(geometry)),
    master_coverage = intersect_area / master_area
  ) %>%
  st_drop_geometry() %>%
  filter(
    master_coverage >= replacement_threshold,
    new_area > master_area
  ) %>%
  group_by(master_row) %>%
  slice_max(master_coverage, n = 1, with_ties = FALSE) %>%
  ungroup()

cat(
  "\nPotential master polygons replaced by larger federal polygons: ",
  nrow(replacement_pairs),
  "\n",
  sep = ""
)

# ==============================================================================
# PART 4. PROVISIONAL REPLACEMENT + FIRST 5% OVERLAP TEST
# ==============================================================================

# Temporarily remove all potential replacement records so that a large federal
# polygon is not rejected merely because it covers the small parks it is meant
# to replace.
provisional_retired_ids <- unique(replacement_pairs$old_park_id)

master_provisional <- master %>%
  filter(!park_id %in% provisional_retired_ids)

new_first_pass <- calculate_source_overlap(
  new,
  master_provisional
)

first_pass_append_ids <- new_first_pass %>%
  filter(overlap_ratio < overlap_threshold) %>%
  pull(new_id)

# Confirm a retirement only if its federal replacement polygon survives the
# first overlap test.
replacement_pairs_confirmed <- replacement_pairs %>%
  filter(new_id %in% first_pass_append_ids)

retired_ids <- unique(replacement_pairs_confirmed$old_park_id)

master_keep <- master %>%
  filter(!park_id %in% retired_ids)

cat(
  "\nConfirmed retired master parks: ",
  length(retired_ids),
  "\n",
  sep = ""
)

# ==============================================================================
# PART 5. FINAL 5% OVERLAP TEST AGAINST RETAINED MASTER
# ==============================================================================

new_with_overlap <- calculate_source_overlap(
  new,
  master_keep
)

new_intersect <- new_with_overlap %>%
  filter(overlap_ratio >= overlap_threshold)

new_nonint <- new_with_overlap %>%
  filter(overlap_ratio < overlap_threshold)

# Safety check: only retire a master record when its replacement polygon is
# still in the final append set.
replacement_pairs_confirmed <- replacement_pairs_confirmed %>%
  filter(new_id %in% new_nonint$new_id)

retired_ids <- unique(replacement_pairs_confirmed$old_park_id)

master_keep <- master %>%
  filter(!park_id %in% retired_ids)

# Recalculate once more against the final retained master.
new_with_overlap <- calculate_source_overlap(
  new,
  master_keep
)

new_intersect <- new_with_overlap %>%
  filter(overlap_ratio >= overlap_threshold)

new_nonint <- new_with_overlap %>%
  filter(overlap_ratio < overlap_threshold)

cat(
  "\nFederal source polygons: ",
  nrow(new),
  "\n",
  "Already represented in retained master: ",
  nrow(new_intersect),
  "\n",
  "Federal polygons to append: ",
  nrow(new_nonint),
  "\n",
  sep = ""
)

# ==============================================================================
# PART 6. VISUAL REVIEW
# ==============================================================================

if (run_visual_check) {
  retired_master <- master %>%
    filter(park_id %in% retired_ids)

  tmap_mode("view")

  print(
    tm_shape(master_keep) +
      tm_polygons(
        fill = "#2F80ED",
        fill_alpha = 0.45,
        col = NA,
        group = "Retained master",
        group.control = "check"
      ) +
      tm_shape(retired_master) +
      tm_polygons(
        fill = "#8E24AA",
        fill_alpha = 0.75,
        col = NA,
        group = "Retired master polygons",
        group.control = "check"
      ) +
      tm_shape(new_intersect) +
      tm_polygons(
        fill = "#E53935",
        fill_alpha = 0.65,
        col = NA,
        group = "Excluded: overlap >= 5%",
        group.control = "check"
      ) +
      tm_shape(new_nonint) +
      tm_polygons(
        fill = "#F9A825",
        fill_alpha = 0.70,
        col = NA,
        group = "Federal polygon to append",
        group.control = "check"
      )
  )
}

# ==============================================================================
# PART 7. STANDARDIZE AND ASSIGN NEW PARK IDs
# ==============================================================================

new_nonint_prepped <- new_nonint %>%
  mutate(
    MA_NAME = blank_to_na(MA_NAME),
    OWNER = standardize_owner_name(OWNER),
    park_id = generate_park_ids(
      n = n(),
      existing_ids = master$park_id
    ),
    ACRES = new_area / 4046.8564224,
    GIS_SRC = src_name,
    CreationDate = create_time,
    Creator = creator,
    EditDate = create_time,
    Editor = creator
  )

new_nonint_selected <- new_nonint_prepped %>%
  select(
    park_id,
    any_of(
      setdiff(
        names(master),
        c("park_id", "geometry")
      )
    ),
    geometry
  )

if (any(is.na(new_nonint_selected$park_id))) {
  stop("Missing park_id values were created for new parks.")
}

if (any(duplicated(new_nonint_selected$park_id))) {
  stop("Duplicated park_id values were created within the new parks.")
}

if (any(new_nonint_selected$park_id %in% master$park_id)) {
  stop("A new park_id duplicates an existing master park_id.")
}

# ==============================================================================
# PART 8. CREATE OLD -> NEW PARK_ID REPLACEMENT TRACKER
# ==============================================================================

replacement_map <- replacement_pairs_confirmed %>%
  select(
    old_park_id,
    old_name,
    new_id,
    master_coverage
  ) %>%
  left_join(
    new_nonint_prepped %>%
      st_drop_geometry() %>%
      select(
        new_id,
        new_park_id = park_id,
        new_name = MA_NAME
      ),
    by = "new_id"
  ) %>%
  select(
    old_park_id,
    old_name,
    new_park_id,
    new_name,
    master_coverage
  )

if (nrow(replacement_map) > 0 && any(is.na(replacement_map$new_park_id))) {
  stop("At least one retired park_id does not have a replacement new_park_id.")
}

# ==============================================================================
# PART 9. COMBINE AND VALIDATE UPDATED BOUNDARY MASTER
# ==============================================================================

master_updated <- bind_rows(
  master_keep,
  new_nonint_selected
) %>%
  st_make_valid()

if (any(is.na(master_updated$park_id) | master_updated$park_id == "")) {
  stop("The updated master contains missing park_id values.")
}

if (any(duplicated(master_updated$park_id))) {
  stop("The updated master contains duplicated park_id values.")
}

if (any(st_is_empty(master_updated))) {
  stop("The updated master contains empty geometries.")
}

expected_rows <- nrow(master_keep) + nrow(new_nonint_selected)

if (nrow(master_updated) != expected_rows) {
  stop("The updated master row count is inconsistent.")
}

if (any(retired_ids %in% master_updated$park_id)) {
  stop("Retired park_id values remain in the updated boundary master.")
}

master_updated <- master_updated %>%
  st_transform(4326)

# ==============================================================================
# PART 10. WRITE OUTPUTS
# ==============================================================================

dir.create(
  output_dir,
  recursive = TRUE,
  showWarnings = FALSE
)

st_write(
  master_updated,
  output_path,
  layer = "boundaries",
  delete_dsn = TRUE,
  quiet = TRUE
)

write_csv(
  replacement_map,
  replacement_path
)

# ==============================================================================
# PART 11. SUMMARY
# ==============================================================================

message("Master Park Boundary Dataset written: ", output_path)
message("Replacement tracker written: ", replacement_path)
message("Previous master parks: ", nrow(master))
message("Retired master parks: ", length(retired_ids))
message("Federal polygons appended: ", nrow(new_nonint_selected))
message("Updated master parks: ", nrow(master_updated))
message("Federal source polygons excluded by 5% overlap rule: ", nrow(new_intersect))

