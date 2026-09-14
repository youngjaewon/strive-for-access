################################################################################
# 02_update_amenities_id49.R
# ==============================================================================
# Strive for Access
#
# Purpose
#   Update the Master Park Amenity Dataset after the PAD-US federal boundary
#   update (Batch ID 48).
#
# Inputs
#   - amenities_20260723_3.xlsx
#   - boundaries_20260914.gpkg
#   - park_id_replacements_20260914.csv
#
# Logic
#   1. Preserve amenity rows for retained park_id values.
#   2. Remove amenity rows belonging to retired park_id values.
#   3. For each replacement new_park_id, merge information from all retired
#      amenity rows mapped to that new park:
#        - Yes/No fields: Yes if any old row is Yes; otherwise No if any No.
#        - Numeric fields: retain the maximum observed value (do not sum).
#        - Other text fields: retain unique nonblank values, separated by "; ".
#   4. Create blank amenity rows for newly added federal parks that do not
#      replace an existing master park.
#   5. Take MA_NAME and OWNER from the updated boundary master.
#   6. Validate one amenity row per boundary park_id and write a dated master.
################################################################################


# ==============================================================================
# PACKAGES
# ==============================================================================

library(tidyverse)
library(sf)
library(readxl)
library(writexl)


# ==============================================================================
# CONFIG
# ==============================================================================

root <- "/Users/ywon3/Library/CloudStorage/Dropbox/03_Strive for Access/Data"

amenities_path <- file.path(
  root,
  "master",
  "amenities",
  "amenities_20260723_3.xlsx"
)

boundary_path <- file.path(
  root,
  "master",
  "boundaries",
  "boundaries_20260914.gpkg"
)

replacement_path <- file.path(
  root,
  "master",
  "boundaries",
  "park_id_replacements_20260914.csv"
)

run_date <- as.Date("2026-09-14")
date_stamp <- format(run_date, "%Y%m%d")

output_dir <- file.path(
  root,
  "master",
  "amenities"
)

output_path <- file.path(
  output_dir,
  paste0("amenities_", date_stamp, ".xlsx")
)


# ==============================================================================
# HELPERS
# ==============================================================================

blank_to_na <- function(x) {
  x <- as.character(x)
  x <- str_squish(x)
  x[x == ""] <- NA_character_
  x
}


combine_values <- function(x) {

  # Completely missing
  if (all(is.na(x))) {
    return(NA)
  }

  # Numeric columns: use maximum, not sum, to avoid double counting facilities
  if (is.numeric(x)) {
    return(max(x, na.rm = TRUE))
  }

  x_chr <- blank_to_na(x)
  x_nonmiss <- x_chr[!is.na(x_chr)]

  if (length(x_nonmiss) == 0) {
    return(NA_character_)
  }

  # Yes/No fields
  vals_lower <- str_to_lower(x_nonmiss)

  if (all(vals_lower %in% c("yes", "no"))) {
    if (any(vals_lower == "yes")) return("Yes")
    return("No")
  }

  # Other text fields: retain unique information
  paste(unique(x_nonmiss), collapse = "; ")
}


# ==============================================================================
# PART 1. READ INPUTS
# ==============================================================================

message("Reading amenity master: ", amenities_path)

amenities <- read_excel(
  amenities_path,
  sheet = 1,
  guess_max = 10000
)

message("Reading updated boundary master: ", boundary_path)

boundaries <- st_read(
  boundary_path,
  quiet = TRUE
) %>%
  st_drop_geometry()

message("Reading park_id replacement tracker: ", replacement_path)

replacement_map <- read_csv(
  replacement_path,
  show_col_types = FALSE
)


# ==============================================================================
# PART 2. VALIDATE INPUTS
# ==============================================================================

required_amenity_fields <- c("park_id", "MA_NAME", "OWNER")
required_boundary_fields <- c("park_id", "MA_NAME", "OWNER")
required_replacement_fields <- c(
  "old_park_id",
  "new_park_id",
  "old_name",
  "new_name"
)

if (!all(required_amenity_fields %in% names(amenities))) {
  stop("Amenity master is missing required fields.")
}

if (!all(required_boundary_fields %in% names(boundaries))) {
  stop("Boundary master is missing required fields.")
}

if (!all(required_replacement_fields %in% names(replacement_map))) {
  stop("Replacement tracker is missing required fields.")
}

if (any(is.na(amenities$park_id) | amenities$park_id == "")) {
  stop("Amenity master contains missing park_id values.")
}

if (any(duplicated(amenities$park_id))) {
  stop("Amenity master contains duplicated park_id values.")
}

if (any(is.na(boundaries$park_id) | boundaries$park_id == "")) {
  stop("Boundary master contains missing park_id values.")
}

if (any(duplicated(boundaries$park_id))) {
  stop("Boundary master contains duplicated park_id values.")
}


# ==============================================================================
# PART 3. IDENTIFY RETIRED / NEW PARK IDs
# ==============================================================================

retired_ids <- unique(replacement_map$old_park_id)
replacement_new_ids <- unique(replacement_map$new_park_id)

new_boundary_ids <- setdiff(
  boundaries$park_id,
  amenities$park_id
)

new_only_ids <- setdiff(
  new_boundary_ids,
  replacement_new_ids
)

cat(
  "\nOriginal amenity rows: ", nrow(amenities),
  "\nRetired amenity park IDs: ", length(retired_ids),
  "\nReplacement new park IDs: ", length(replacement_new_ids),
  "\nNew parks without retired predecessors: ", length(new_only_ids),
  "\nUpdated boundary parks: ", nrow(boundaries),
  "\n",
  sep = ""
)


# ==============================================================================
# PART 4. PRESERVE RETAINED AMENITY RECORDS
# ==============================================================================

amenities_keep <- amenities %>%
  filter(!park_id %in% retired_ids)


# ==============================================================================
# PART 5. AGGREGATE AMENITIES FOR REPLACEMENT PARKS
# ==============================================================================

amenity_fields <- setdiff(
  names(amenities),
  c("park_id", "MA_NAME", "OWNER")
)

replacement_old <- amenities %>%
  filter(park_id %in% retired_ids) %>%
  inner_join(
    replacement_map %>%
      select(old_park_id, new_park_id),
    by = c("park_id" = "old_park_id")
  )


replacement_amenities <- replacement_old %>%
  group_by(new_park_id) %>%
  summarise(
    across(
      all_of(amenity_fields),
      combine_values
    ),
    .groups = "drop"
  ) %>%
  rename(park_id = new_park_id) %>%
  left_join(
    boundaries %>%
      select(park_id, MA_NAME, OWNER),
    by = "park_id"
  ) %>%
  select(
    park_id,
    MA_NAME,
    OWNER,
    all_of(amenity_fields)
  )


# ==============================================================================
# PART 6. CREATE BLANK ROWS FOR BRAND-NEW FEDERAL PARKS
# ==============================================================================

new_blank <- boundaries %>%
  filter(park_id %in% new_only_ids) %>%
  select(park_id, MA_NAME, OWNER)


for (nm in amenity_fields) {

  # Match the original amenity column type where possible
  if (is.numeric(amenities[[nm]])) {
    new_blank[[nm]] <- NA_real_
  } else {
    new_blank[[nm]] <- NA_character_
  }
}


new_blank <- new_blank %>%
  select(
    park_id,
    MA_NAME,
    OWNER,
    all_of(amenity_fields)
  )


# ==============================================================================
# PART 7. COMBINE UPDATED AMENITY MASTER
# ==============================================================================

amenities_updated <- bind_rows(
  amenities_keep,
  replacement_amenities,
  new_blank
) %>%
  # Always use the current name/owner from the boundary master
  select(-MA_NAME, -OWNER) %>%
  left_join(
    boundaries %>%
      select(park_id, MA_NAME, OWNER),
    by = "park_id"
  ) %>%
  select(
    park_id,
    MA_NAME,
    OWNER,
    all_of(amenity_fields)
  ) %>%
  arrange(park_id)


# ==============================================================================
# PART 8. QA / QC
# ==============================================================================

if (any(is.na(amenities_updated$park_id) | amenities_updated$park_id == "")) {
  stop("Updated amenity master contains missing park_id values.")
}

if (any(duplicated(amenities_updated$park_id))) {
  stop("Updated amenity master contains duplicated park_id values.")
}

if (!setequal(amenities_updated$park_id, boundaries$park_id)) {

  missing_in_amenities <- setdiff(
    boundaries$park_id,
    amenities_updated$park_id
  )

  extra_in_amenities <- setdiff(
    amenities_updated$park_id,
    boundaries$park_id
  )

  print(missing_in_amenities)
  print(extra_in_amenities)

  stop("Amenity park_id values do not exactly match the updated boundary master.")
}

if (nrow(amenities_updated) != nrow(boundaries)) {
  stop("Amenity row count does not match boundary row count.")
}


# Summary of replacement aggregation
replacement_summary <- replacement_map %>%
  count(
    new_park_id,
    new_name,
    name = "old_parks_merged"
  ) %>%
  arrange(desc(old_parks_merged), new_name)

cat("\nReplacement amenity summary:\n")
print(replacement_summary, n = Inf)


# ==============================================================================
# PART 9. WRITE OUTPUT
# ==============================================================================

dir.create(
  output_dir,
  recursive = TRUE,
  showWarnings = FALSE
)

write_xlsx(
  amenities_updated,
  output_path
)


# ==============================================================================
# SUMMARY
# ==============================================================================

message("Master Park Amenity Dataset written: ", output_path)
message("Previous amenity parks: ", nrow(amenities))
message("Retired amenity park IDs removed: ", length(retired_ids))
message("Replacement amenity rows created: ", nrow(replacement_amenities))
message("Blank rows created for new federal parks: ", nrow(new_blank))
message("Updated amenity parks: ", nrow(amenities_updated))
