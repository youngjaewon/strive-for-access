# =============================================================================
# 05_create_exb_data.R
# -----------------------------------------------------------------------------
# Strive for Access (SFA) - ArcGIS Experience Builder data preparation
#
# Purpose:
#   Build the map layers for the Experience Builder app from the versioned
#   SFA master datasets. This is a downstream step that runs after the
#   01-04 pipeline has produced the master boundary, amenity, and drive
#   time service area datasets.
#
# Inputs (versioned SFA master datasets):
#   boundaries/boundaries_YYYYMMDD.gpkg         park polygons (park_id)
#   amenities/amenities_YYYYMMDD.csv            amenity table (park_id)
#   service_areas/service_areas_YYYYMMDD.gpkg   10 min service area per park
#
# Outputs (root/exb/, stable filenames for the EXB feature layers):
#   rec_lands.geojson                 park polygons with amenity flags
#   service_areas_by_park.geojson     per park service areas with flags
#   dissolved_buffer_all.geojson      union of all park service areas
#   dissolved_buffer_{amenity}.geojson  union per amenity
#   census_tracts_final.geojson       tracts with desert, SVI, percentiles
#
# Usage:
#   Set the counties, amenities, and input dates in the CONFIG section,
#   then run the whole script.
# =============================================================================

# --- Packages ----------------------------------------------------------------

library(tidyverse)
library(sf)
library(tidycensus)
library(tigris)


# =============================================================================
# CONFIG (edit counties, amenities, and input dates, then run)
# =============================================================================

# Paths
root <- "/Volumes/Strive4Access/Data"

boundary_path     <- file.path(root, "boundaries/boundaries_20251014.gpkg")
amenities_path    <- file.path(root, "amenities/amenities_20251014.csv")
service_area_path <- file.path(root, "service_areas/service_areas_20251014.gpkg")

# Output directory (stable filenames so the EXB app layers stay linked)
output_dir <- file.path(root, "exb")

# Counties included in the app
target_counties <- c("Wake", "Alamance")
state_name      <- "NC"

# Amenities surfaced in the app:
#   key    : suffix used in column and file names (has_{key}, pct_desert_{key})
#   column : amenity column name in the master amenity table
#   label  : display label used in the app
amenity_config <- tribble(
  ~key,         ~column,      ~label,
  "playground", "Playground", "Playground",
  "dogpark",    "DogPark",    "Dog Park",
  "swimpool",   "SwimPool",   "Swimming Pool"
)

# Census settings
acs_year <- 2022
svi_url  <- "https://svi.cdc.gov/Documents/Data/2022/csv/states/NorthCarolina.csv"

# Analysis settings
crs_projected    <- 26917   # projected CRS for area calculations
desert_threshold <- 90      # pct_desert at or above this value flags a desert tract


# =============================================================================
# PART 1: PARK LAYER (boundaries + amenity flags + county)
# =============================================================================

message("Reading master boundaries: ", boundary_path)
boundaries <- st_read(boundary_path, quiet = TRUE) %>% st_make_valid()

message("Reading amenity table: ", amenities_path)
amenities <- read_csv(amenities_path, show_col_types = FALSE)

stopifnot("park_id" %in% names(boundaries))
stopifnot("park_id" %in% names(amenities))
stopifnot(all(amenity_config$column %in% names(amenities)))

# County boundaries for spatial assignment
county_sf <- counties(state = state_name, cb = TRUE, progress_bar = FALSE) %>%
  filter(NAME %in% target_counties) %>%
  select(county_name = NAME)

# Assign each park to one county by its representative point
parks <- boundaries %>%
  st_transform(st_crs(county_sf)) %>%
  st_join(county_sf, join = st_intersects,
          left = FALSE, largest = TRUE)

# Attach amenity flags (Yes -> 1, otherwise 0)
amenity_flags <- amenities %>%
  select(park_id, all_of(amenity_config$column)) %>%
  mutate(across(
    all_of(amenity_config$column),
    ~ if_else(.x == "Yes", 1L, 0L, missing = 0L)
  )) %>%
  rename_with(
    ~ paste0("has_", amenity_config$key[match(.x, amenity_config$column)]),
    all_of(amenity_config$column)
  )

flag_cols <- paste0("has_", amenity_config$key)

rec_lands <- parks %>%
  left_join(amenity_flags, by = "park_id") %>%
  mutate(across(all_of(flag_cols), ~ replace_na(.x, 0L))) %>%
  select(park_id, MA_NAME, county_name, all_of(flag_cols), geometry)

if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

st_write(rec_lands %>% st_transform(4326),
         file.path(output_dir, "rec_lands.geojson"),
         delete_dsn = TRUE, quiet = TRUE)

cat("Recreation lands:", nrow(rec_lands), "\n")
print(count(st_drop_geometry(rec_lands), county_name))


# =============================================================================
# PART 2: SERVICE AREAS BY PARK (with amenity flags)
# =============================================================================

message("Reading service areas: ", service_area_path)
service_areas <- st_read(service_area_path, quiet = TRUE) %>% st_make_valid()

stopifnot("park_id" %in% names(service_areas))

service_areas_by_park <- service_areas %>%
  inner_join(
    rec_lands %>% st_drop_geometry() %>%
      select(park_id, county_name, all_of(flag_cols)),
    by = "park_id"
  )

st_write(service_areas_by_park %>% st_transform(4326),
         file.path(output_dir, "service_areas_by_park.geojson"),
         delete_dsn = TRUE, quiet = TRUE)

cat("\nService areas by park:", nrow(service_areas_by_park), "\n")


# =============================================================================
# PART 3: DISSOLVED BUFFERS (all parks, then per amenity)
# =============================================================================

sa_utm <- service_areas_by_park %>% st_transform(crs_projected)

dissolve_buffer <- function(sf_obj, type, label) {
  if (nrow(sf_obj) == 0) return(NULL)
  sf_obj %>%
    st_union() %>%
    st_sf(geometry = .) %>%
    mutate(buffer_type = type, amenity_label = label)
}

dissolved <- list(
  all = dissolve_buffer(sa_utm, "all", "All Recreation Lands")
)

for (i in seq_len(nrow(amenity_config))) {
  key <- amenity_config$key[i]
  dissolved[[key]] <- dissolve_buffer(
    sa_utm %>% filter(.data[[paste0("has_", key)]] == 1),
    key,
    amenity_config$label[i]
  )
}

# Write each dissolved layer as a separate file
for (type in names(dissolved)) {
  if (is.null(dissolved[[type]])) {
    message("Dissolved buffer skipped (no parks): ", type)
    next
  }
  st_write(dissolved[[type]] %>% st_transform(4326),
           file.path(output_dir, paste0("dissolved_buffer_", type, ".geojson")),
           delete_dsn = TRUE, quiet = TRUE)
}

cat("\nDissolved buffers written:",
    paste(names(compact(dissolved)), collapse = ", "), "\n")


# =============================================================================
# PART 4: CENSUS TRACTS
# =============================================================================

# census_api_key("YOUR_KEY_HERE", install = TRUE)   # set once if needed

tracts <- get_acs(
  geography = "tract",
  variables = c(total_pop = "B01003_001"),
  state     = state_name,
  county    = target_counties,
  year      = acs_year,
  geometry  = TRUE
) %>%
  select(GEOID, NAME, geometry) %>%
  distinct(GEOID, .keep_all = TRUE) %>%
  mutate(
    county_name = str_extract(NAME, paste(target_counties, collapse = "|"))
  ) %>%
  st_transform(crs_projected)

cat("\nCensus tracts:", nrow(tracts), "\n")


# =============================================================================
# PART 5: PERCENT DESERT PER TRACT
# =============================================================================

# Share of each tract NOT covered by the dissolved service area buffer.
calculate_pct_desert <- function(tracts, dissolved_buffer) {

  tracts <- tracts %>% mutate(tract_area = as.numeric(st_area(geometry)))

  # Tracts entirely unserved when no buffer exists
  if (is.null(dissolved_buffer)) {
    return(tracts %>% st_drop_geometry() %>%
             select(GEOID) %>% mutate(pct_desert = 100))
  }

  dissolved_buffer <- st_transform(dissolved_buffer, st_crs(tracts))

  served <- st_intersection(tracts %>% select(GEOID, geometry),
                            dissolved_buffer) %>%
    mutate(served_area = as.numeric(st_area(geometry))) %>%
    st_drop_geometry() %>%
    summarise(served_area = sum(served_area), .by = GEOID)

  tracts %>%
    st_drop_geometry() %>%
    select(GEOID, tract_area) %>%
    left_join(served, by = "GEOID") %>%
    mutate(
      served_area = replace_na(served_area, 0),
      pct_desert  = pmax(0, round((1 - served_area / tract_area) * 100, 2))
    ) %>%
    select(GEOID, pct_desert)
}

desert_types <- c("all", amenity_config$key)

pct_desert_tables <- map(desert_types, function(type) {
  calculate_pct_desert(tracts, dissolved[[type]]) %>%
    rename(!!paste0("pct_desert_", type) := pct_desert)
})

tracts_final <- reduce(pct_desert_tables, left_join, by = "GEOID",
                       .init = tracts)

cat("\nPercent desert summary:\n")
print(summary(tracts_final %>% st_drop_geometry() %>%
                select(starts_with("pct_desert"))))


# =============================================================================
# PART 6: SVI & DEMOGRAPHIC VARIABLES
# =============================================================================

message("Downloading SVI data: ", svi_url)
temp_svi <- tempfile(fileext = ".csv")
download.file(svi_url, temp_svi, mode = "wb")

svi_data <- read.csv(temp_svi) %>%
  filter(COUNTY %in% paste(target_counties, "County")) %>%
  mutate(GEOID = as.character(FIPS)) %>%
  select(
    GEOID,
    RPL_THEMES,      # Overall SVI percentile (0-1)
    RPL_THEME1,      # Socioeconomic Status percentile
    RPL_THEME2,      # Household Composition & Disability percentile
    RPL_THEME3,      # Minority Status & Language percentile
    RPL_THEME4,      # Housing Type & Transportation percentile
    E_TOTPOP,        # Total population
    E_NOVEH,         # No vehicle households
    E_POV150,        # Below 150% poverty
    E_AGE17,         # Age under 18
    E_AGE65,         # Age 65+
    E_NOINT,         # No internet
    E_LIMENG         # Limited English
  ) %>%
  mutate(
    # Convert percentiles to 0-100 scale (SVI codes missing as -999)
    svi_overall       = ifelse(RPL_THEMES >= 0, RPL_THEMES * 100, NA),
    svi_socioeconomic = ifelse(RPL_THEME1 >= 0, RPL_THEME1 * 100, NA),
    svi_household     = ifelse(RPL_THEME2 >= 0, RPL_THEME2 * 100, NA),
    svi_minority      = ifelse(RPL_THEME3 >= 0, RPL_THEME3 * 100, NA),
    svi_housing       = ifelse(RPL_THEME4 >= 0, RPL_THEME4 * 100, NA),

    # Demographic percentages (guard against zero population)
    no_vehicle_pct      = ifelse(E_TOTPOP > 0, (E_NOVEH  / E_TOTPOP) * 100, NA),
    poverty_150_pct     = ifelse(E_TOTPOP > 0, (E_POV150 / E_TOTPOP) * 100, NA),
    under_18_pct        = ifelse(E_TOTPOP > 0, (E_AGE17  / E_TOTPOP) * 100, NA),
    age_65plus_pct      = ifelse(E_TOTPOP > 0, (E_AGE65  / E_TOTPOP) * 100, NA),
    no_internet_pct     = ifelse(E_TOTPOP > 0, (E_NOINT  / E_TOTPOP) * 100, NA),
    limited_english_pct = ifelse(E_TOTPOP > 0, (E_LIMENG / E_TOTPOP) * 100, NA)
  ) %>%
  select(
    GEOID, E_TOTPOP,
    starts_with("svi_"),
    ends_with("_pct")
  )

tracts_final <- tracts_final %>%
  left_join(svi_data, by = "GEOID")

cat("\nSVI joined:", sum(!is.na(tracts_final$svi_overall)), "/",
    nrow(tracts_final), "tracts\n")


# =============================================================================
# PART 7: PERCENTILES, DESERT CLASSES & FLAGS
# =============================================================================

calc_percentile <- function(x) {
  ecdf_func <- ecdf(x[!is.na(x)])
  percentile <- ecdf_func(x) * 100
  percentile[is.na(x)] <- NA
  percentile
}

categorize_desert <- function(pct) {
  cut(pct,
      breaks = seq(0, 100, by = 10),
      labels = paste0(seq(0, 90, 10), "-", seq(10, 100, 10), "%"),
      include.lowest = TRUE, right = FALSE) %>%
    as.character() %>%
    replace_na("90-100%")
}

tracts_final <- tracts_final %>%
  mutate(
    # Desert percentiles: ranked across the full dataset
    across(starts_with("pct_desert_"),
           calc_percentile,
           .names = "pctile_{str_remove(.col, 'pct_')}"),
    # Desert classes: 10 point bins
    across(starts_with("pct_desert_"),
           categorize_desert,
           .names = "{str_replace(.col, 'pct_desert', 'desert_class')}")
  ) %>%
  # Demographic percentiles: ranked within each county (50 = county median)
  group_by(county_name) %>%
  mutate(
    pctile_svi        = calc_percentile(svi_overall),
    pctile_no_vehicle = calc_percentile(no_vehicle_pct),
    pctile_poverty    = calc_percentile(poverty_150_pct),
    pctile_under18    = calc_percentile(under_18_pct),
    pctile_age65plus  = calc_percentile(age_65plus_pct)
  ) %>%
  ungroup()

# Binary desert flags per amenity (for the EXB Group Filter widget)
for (key in amenity_config$key) {
  tracts_final[[paste0("is_desert_", key)]] <-
    if_else(tracts_final[[paste0("pct_desert_", key)]] >= desert_threshold,
            1L, 0L)
}

cat("\nDesert flag counts (pct_desert >= ", desert_threshold, "):\n", sep = "")
for (key in amenity_config$key) {
  cat("  ", key, ": ",
      sum(tracts_final[[paste0("is_desert_", key)]] == 1, na.rm = TRUE),
      " tracts\n", sep = "")
}


# =============================================================================
# PART 8: WRITE FINAL TRACT LAYER
# =============================================================================

st_write(tracts_final %>% st_transform(4326),
         file.path(output_dir, "census_tracts_final.geojson"),
         delete_dsn = TRUE, quiet = TRUE)

message("EXB layers written to: ", output_dir)
cat("Final census tracts:", nrow(tracts_final), "\n")
