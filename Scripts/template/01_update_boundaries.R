# =============================================================================
# 01_update_park_boundaries.R
# =============================================================================
# Strive for Access
# Park Boundary Dataset pipeline
#
# Purpose
#   Read a new external park boundary source, compare it with the current
#   Master Park Boundary Dataset, exclude source polygons whose area overlaps
#   the master by at least 5 percent, append the remaining polygons as new
#   parks, preserve existing park_id values, assign 12 character park_id values
#   only to appended parks, and write a new dated master boundary file.
#
# New source
#   Piedmont Triad Regional Council park boundary dataset
#
# Field mapping
#   ParkNam becomes MA_NAME
#   MngngAg becomes OWNER
#
# Identification rule
#   Existing master park_id values are preserved.
#   New parks receive 12 character hexadecimal identifiers generated with
#   ids::random_id(bytes = 6).
# =============================================================================


# =============================================================================
# PACKAGES
# =============================================================================

library(tidyverse)
library(sf)
library(tmap)
library(ids)


# =============================================================================
# CONFIG
# =============================================================================

root <- "/Users/ywon3/Library/CloudStorage/Dropbox/03_Strive for Access/Data"

master_path <- file.path(
  root,
  "master",
  "boundaries",
  "boundaries_20260511.gpkg"
)

new_path <- file.path(
  root,
  "source",
  "PTRC"
)

run_date <- Sys.Date() # or as.Date("2025-07-10")
date_stamp <- format(run_date, "%Y%m%d")

output_dir <- file.path(
  root,
  "master",
  "boundaries"
)

output_path <- file.path(
  output_dir,
  paste0("boundaries_", date_stamp, ".gpkg")
)

src_name <- "Piedmont Triad Regional Council"
creator <- "youngjaewon"

create_time <- as.POSIXct(
  paste(run_date, "12:00:00"),
  tz = "America/New_York"
)

# Target master field = source field
col_map <- c(
  MA_NAME = "ParkNam",
  OWNER = "MngngAg"
)

# NAD83 North Carolina, meters
crs_projected <- 32119

# Source polygons overlapping the master by at least 5 percent
# are treated as already represented.
overlap_threshold <- 0.05

run_visual_check <- TRUE


# =============================================================================
# HELPERS
# =============================================================================

generate_park_ids <- function(n, existing_ids = character()) {
  
  if (n == 0) {
    return(character())
  }
  
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
    
    new_ids <- c(
      new_ids,
      candidates
    )
  }
  
  new_ids
}


standardize_geometry_name <- function(x) {
  
  geometry_name <- attr(
    x,
    "sf_column"
  )
  
  if (is.null(geometry_name)) {
    stop("The object does not have an active sf geometry column.")
  }
  
  if (geometry_name != "geometry") {
    
    names(x)[names(x) == geometry_name] <- "geometry"
    
    attr(
      x,
      "sf_column"
    ) <- "geometry"
  }
  
  x
}


prepare_polygons <- function(x, crs) {
  
  x |>
    standardize_geometry_name() |>
    st_transform(crs) |>
    st_make_valid() |>
    st_collection_extract(
      "POLYGON",
      warn = FALSE
    ) |>
    st_cast(
      "MULTIPOLYGON",
      warn = FALSE
    )
}


blank_to_na <- function(x) {
  
  x |>
    as.character() |>
    str_squish() |>
    na_if("")
}


standardize_owner_name <- function(x) {
  
  x <- blank_to_na(x)
  
  case_when(
    str_to_lower(x) == "mount airy" ~ "Mount Airy",
    TRUE ~ x
  )
}


# =============================================================================
# PART 1
# READ AND VALIDATE INPUTS
# =============================================================================

message(
  "Reading master: ",
  master_path
)

master <- st_read(
  master_path,
  quiet = TRUE
) |>
  standardize_geometry_name()

message(
  "Reading new source: ",
  new_path
)

new <- st_read(
  new_path,
  quiet = TRUE
) |>
  standardize_geometry_name()

if (is.na(st_crs(master))) {
  stop("The master boundary dataset does not have a CRS.")
}

if (is.na(st_crs(new))) {
  stop("The new boundary source does not have a CRS.")
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

missing_source_fields <- setdiff(
  unname(col_map),
  names(new)
)

if (length(missing_source_fields) > 0) {
  
  stop(
    "The new source is missing mapped fields: ",
    paste(
      missing_source_fields,
      collapse = ", "
    )
  )
}

missing_master_fields <- setdiff(
  names(col_map),
  names(master)
)

if (length(missing_master_fields) > 0) {
  
  stop(
    "The master dataset is missing target fields: ",
    paste(
      missing_master_fields,
      collapse = ", "
    )
  )
}

master <- prepare_polygons(
  master,
  crs_projected
)

new <- prepare_polygons(
  new,
  crs_projected
)

if (any(st_is_empty(master))) {
  stop("The master boundary dataset contains empty geometries.")
}

if (any(st_is_empty(new))) {
  stop("The new boundary source contains empty geometries.")
}

sf::sf_use_s2(FALSE)


# =============================================================================
# PART 2
# DIAGNOSTIC INTERSECTION COUNTS
# =============================================================================

overlap_matrix <- matrix(
  NA_integer_,
  nrow = 2,
  ncol = 2,
  dimnames = list(
    c("master", "new"),
    c("master", "new")
  )
)

overlap_matrix["master", "new"] <- sum(
  lengths(
    st_intersects(
      master,
      new
    )
  ) > 0
)

overlap_matrix["new", "master"] <- sum(
  lengths(
    st_intersects(
      new,
      master
    )
  ) > 0
)

overlap_matrix["master", "master"] <- sum(
  lengths(
    st_intersects(
      master,
      master
    )
  ) > 0
)

overlap_matrix["new", "new"] <- sum(
  lengths(
    st_intersects(
      new,
      new
    )
  ) > 0
)

cat("\nIntersection counts\n")

print(overlap_matrix)


# =============================================================================
# PART 3
# CALCULATE OVERLAP WITH THE MASTER
# =============================================================================

new <- new |>
  mutate(
    new_id = row_number(),
    new_area = as.numeric(
      st_area(geometry)
    )
  )

if (any(!is.finite(new$new_area) | new$new_area <= 0)) {
  stop("The new boundary source contains invalid polygon areas.")
}

# Union the master before calculating overlap so that overlapping
# master polygons do not cause the same area to be counted repeatedly.

master_union <- st_sf(
  geometry = st_union(
    st_geometry(master)
  ),
  crs = st_crs(master)
) |>
  st_make_valid()

new_master_intersections <- suppressWarnings(
  st_intersection(
    new |>
      select(new_id),
    master_union
  )
) |>
  mutate(
    intersect_area = as.numeric(
      st_area(geometry)
    )
  ) |>
  st_drop_geometry() |>
  group_by(new_id) |>
  summarise(
    total_overlap = sum(intersect_area),
    .groups = "drop"
  )

new_with_overlap <- new |>
  left_join(
    new_master_intersections,
    by = "new_id"
  ) |>
  mutate(
    total_overlap = replace_na(
      total_overlap,
      0
    ),
    overlap_ratio = total_overlap / new_area
  )

new_intersect <- new_with_overlap |>
  filter(
    overlap_ratio >= overlap_threshold
  )

new_nonint <- new_with_overlap |>
  filter(
    overlap_ratio < overlap_threshold
  )

cat(
  "\nNew source features: ",
  nrow(new),
  "\n",
  "Already represented in master: ",
  nrow(new_intersect),
  "\n",
  "New parks to append: ",
  nrow(new_nonint),
  "\n",
  sep = ""
)


# =============================================================================
# PART 4
# VISUAL REVIEW
# =============================================================================

if (run_visual_check) {
  
  tmap_mode("view")
  
  print(
    tm_shape(master) +
      tm_polygons(
        fill = "#2F80ED",
        fill_alpha = 0.60,
        col = NA,
        group = "Current master",
        group.control = "check"
      ) +
      
      tm_shape(new_intersect) +
      tm_polygons(
        fill = "#E53935",
        fill_alpha = 0.80,
        col = NA,
        group = "Excluded: overlap ≥ 5%",
        group.control = "check"
      ) +
      
      tm_shape(new_nonint) +
      tm_polygons(
        fill = "#F9A825",
        fill_alpha = 0.85,
        col = NA,
        group = "New park to append",
        group.control = "check"
      ) +
      
      tm_add_legend(
        type = "polygons",
        title = "Boundary status",
        fill = c(
          "#2F80ED",
          "#E53935",
          "#F9A825"
        ),
        labels = c(
          "Current master",
          "Excluded: overlap ≥ 5%",
          "New park to append"
        ),
        position = c("right", "bottom")
      )
  )
}

# =============================================================================
# PART 5
# STANDARDIZE NEW PARKS
# =============================================================================

new_nonint_renamed <- new_nonint |>
  rename(
    all_of(col_map)
  ) |>
  mutate(
    MA_NAME = blank_to_na(MA_NAME),
    OWNER = standardize_owner_name(OWNER)
  )

new_nonint_selected <- new_nonint_renamed |>
  mutate(
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
  ) |>
  select(
    park_id,
    any_of(
      setdiff(
        names(master),
        c(
          "park_id",
          "geometry"
        )
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


# =============================================================================
# PART 6
# COMBINE AND VALIDATE
# =============================================================================

master_updated <- bind_rows(
  master,
  new_nonint_selected
) |>
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

expected_rows <- nrow(master) + nrow(new_nonint_selected)

if (nrow(master_updated) != expected_rows) {
  stop("The updated master row count is inconsistent.")
}

master_updated <- master_updated |>
  st_transform(4326)


# =============================================================================
# PART 7
# WRITE OUTPUT
# =============================================================================

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


# =============================================================================
# SUMMARY
# =============================================================================

message(
  "Master Park Boundary Dataset written: ",
  output_path
)

message(
  "Previous master parks: ",
  nrow(master)
)

message(
  "New parks appended: ",
  nrow(new_nonint_selected)
)

message(
  "Updated master parks: ",
  nrow(master_updated)
)

message(
  "Source polygons excluded by overlap rule: ",
  nrow(new_intersect)
)
