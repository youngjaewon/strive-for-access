# =============================================================================
# 02c_update_amenities_survey123.R
# Strive for Access (SFA): Survey123 amenity update
# =============================================================================

library(arcgislayers)
library(tidyverse)
library(sf)
library(readxl)
library(writexl)

source("./Scripts/template/match_survey_to_master.R")


# =============================================================================
# CONFIG
# =============================================================================

root = "/Users/ywon3/Library/CloudStorage/Dropbox/03_Strive for Access/Data"

boundary_path = file.path(root, "master", "boundaries", "boundaries_20260914.gpkg")

amenities_path = file.path(root, "master", "amenities", "amenities_20260914.xlsx")

output_path = file.path(root, "master", "amenities", "amenities_20260924.xlsx")

raw_path = file.path(root, "Survey123", "survey123_raw_20260924.xlsx")

page_size = 500
default_tolerance_m = 25
print_rows = 25


# Regional Survey123 FeatureServers

survey_url = paste0(
  "https://services1.arcgis.com/aT1T0pU1ZdpuDk1t/",
  "arcgis/rest/services/survey123_%s_results/FeatureServer"
)

survey_regions = tribble(
  ~region,          ~service_id,
  "Pilot",          "1a3132b5c132457e8624be6c803862c8",
  "Central North",  "b0970fafced140c3b34d6e0707f4e6dd",
  "Central South",  "f8b28bb4b9494b50b3eb7a172161f981",
  "Northeast",      "27b5568b85fc417296c92a648799febb",
  "Southeast",      "a81fddeeb9fb450980ce2f6ca6ecc8ee",
  "Triad",          "c346d074629346e1b83a67693e60ff69",
  "West",           "c31f8f893fe141aaa2be359a4a98dbd7"
) |>
  mutate(url = sprintf(survey_url, service_id))


# Pilot and Triad have no recorded default location

default_locations = tribble(
  ~region,          ~def_lat,   ~def_lon,
  "Southeast",      34.875946,  -77.716970,
  "West",           35.637734,  -82.670282,
  "Central South",  35.056009,  -79.889821,
  "Central North",  35.999763,  -80.805349,
  "Northeast",      36.068863,  -77.497242
)


# =============================================================================
# PART 1: HELPERS
# =============================================================================

num_pattern = "count$|mileage$|^acres$"

read_amenity_table = function(path) {
  
  ext = str_to_lower(tools::file_ext(path))
  
  if (ext == "csv") {
    
    out = read_csv(
      path,
      col_types = cols(.default = col_character())
    )
    
  } else if (ext %in% c("xlsx", "xlsm", "xls")) {
    
    out = read_excel(
      path,
      col_types = "text"
    )
    
  } else {
    
    stop("Unsupported amenity table format: ", ext)
  }
  
  out |>
    mutate(
      across(
        matches(num_pattern),
        \(x) suppressWarnings(as.numeric(x))
      )
    )
}


clean_text = function(x) {
  
  x = str_squish(as.character(x))
  x[is.na(x) | x == ""] = NA_character_
  
  x
}


is_yes = function(x) {
  
  replace_na(
    str_to_lower(clean_text(x)) == "yes",
    FALSE
  )
}


summarise_yes_no = function(x) {
  
  x = str_to_lower(clean_text(x))
  x = x[!is.na(x)]
  
  if (length(x) == 0) return(NA_character_)
  if (any(x == "yes")) return("Yes")
  if (all(x == "no")) return("No")
  
  NA_character_
}


summarise_count = function(x) {
  
  x = suppressWarnings(as.numeric(x))
  x = x[!is.na(x)]
  
  if (length(x) == 0) NA_real_ else max(x)
}


union_values = function(x) {
  
  x = str_split(as.character(x), ",") |>
    unlist() |>
    str_squish()
  
  x = unique(x[!is.na(x) & x != ""])
  
  if (length(x) == 0) NA_character_ else paste(x, collapse = ",")
}


union_text = function(x) {
  
  x = str_split(as.character(x), "\\s*;\\s*") |>
    unlist() |>
    str_squish()
  
  x = unique(x[!is.na(x) & x != ""])
  
  if (length(x) == 0) NA_character_ else paste(x, collapse = "; ")
}


combine_values = function(x, type) {
  
  switch(
    type,
    yes_no = summarise_yes_no(x),
    count = as.character(summarise_count(x)),
    choice = union_values(x),
    multi_select = union_values(x),
    text = union_text(x)
  )
}


# =============================================================================
# PART 2: LOAD DATA
# =============================================================================

message(
  "Reading Survey123 responses from ",
  nrow(survey_regions),
  " regions"
)

survey_data = map2(
  survey_regions$region,
  survey_regions$url,
  \(rg, url) {
    
    message("  ", rg)
    
    arc_open(url) |>
      get_layer(id = 0) |>
      arc_select(page_size = page_size) |>
      mutate(region = rg, .before = 1)
  }
) |>
  bind_rows()


stopifnot(
  !file.exists(output_path),
  inherits(survey_data, "sf"),
  nrow(survey_data) > 0
)

if (is.na(st_crs(survey_data))) {
  survey_data = st_set_crs(survey_data, 4326)
}


message("Reading master boundaries: ", boundary_path)
boundaries = st_read(boundary_path, quiet = TRUE)

message("Reading amenity table: ", amenities_path)
amenities = read_amenity_table(amenities_path)


stopifnot(
  "park_id" %in% names(boundaries),
  "park_id" %in% names(amenities),
  !anyNA(boundaries$park_id),
  !anyNA(amenities$park_id),
  !anyDuplicated(boundaries$park_id),
  !anyDuplicated(amenities$park_id),
  setequal(boundaries$park_id, amenities$park_id)
)


cat("\nResponses pulled by region:\n")
print(count(st_drop_geometry(survey_data), region))

cat(
  "\nMaster boundaries:", nrow(boundaries),
  "\nAmenity records:", nrow(amenities),
  "\nSurvey responses:", nrow(survey_data),
  "\n"
)


# =============================================================================
# PART 3: ARCHIVE RAW RESPONSES AND DROP DEFAULT LOCATIONS
# =============================================================================

survey_data = survey_data |>
  left_join(default_locations, by = "region") |>
  mutate(
    pt = st_transform(geometry, 4326),
    
    lon = map_dbl(pt, 1),
    lat = map_dbl(pt, 2),
    
    default_geom = st_sfc(
      map2(
        def_lon,
        def_lat,
        \(x, y) {
          if (is.na(x)) st_point() else st_point(c(x, y))
        }
      ),
      crs = 4326
    ),
    
    dist_to_default = as.numeric(
      st_distance(
        pt,
        default_geom,
        by_element = TRUE
      )
    ),
    
    at_default = !is.na(dist_to_default) &
      dist_to_default <= default_tolerance_m
  )


# Preserve all Survey123 fields before filtering

dir.create(
  dirname(raw_path),
  recursive = TRUE,
  showWarnings = FALSE
)

survey_data |>
  st_drop_geometry() |>
  select(
    !any_of(
      c(
        "pt",
        "default_geom",
        "def_lat",
        "def_lon"
      )
    )
  ) |>
  write_xlsx(raw_path)

message("Raw Survey123 archive written: ", raw_path)


cat("\nResponses at default locations, excluded by region:\n")

print(
  survey_data |>
    st_drop_geometry() |>
    filter(at_default) |>
    count(region)
)


survey_data = survey_data |>
  filter(!at_default) |>
  select(
    !any_of(
      c(
        "pt",
        "lon",
        "lat",
        "def_lat",
        "def_lon",
        "default_geom",
        "dist_to_default",
        "at_default"
      )
    )
  )

cat(
  "Responses retained after default location filter:",
  nrow(survey_data),
  "\n"
)


# =============================================================================
# PART 4: FIELD MAPPING
# =============================================================================

# value_type:
# yes_no       presence or absence
# count        counts and mileage
# choice       single choice
# multi_select multiple selections
# text         free text

amenity_map = tribble(
  ~survey_field, ~master_field, ~value_type,
  
  "aircraft_flying", "AircraftFlying", "yes_no",
  "fitnesschallenge_course", "Fitness_ChallengeCourse", "yes_no",
  "climbing_wallbouldering", "ClimbingWall", "yes_no",
  "low_ropes_course", "LowRopes", "yes_no",
  "high_ropes_course", "HighRopes", "yes_no",
  "shooting_range", "ShootingRange", "yes_no",
  "skate_park", "SkatePark", "yes_no",
  "snow_ice_activities", "SnowAndIce", "yes_no",
  "pump_track", "PumpTrack", "yes_no",
  "swimming_pool", "SwimPool", "yes_no",
  "splashpad", "Sprayground", "yes_no",
  "wildlife_observation_area", "WildlifeObservation", "yes_no",
  
  "disc_golf", "DiscGolf", "yes_no",
  "number_of_disc_courses", "DiscCourseCount", "count",
  "total_number_of_holes", "Disc_golf_hole_count", "count",
  
  "golf_course", "GolfCourse", "yes_no",
  "golf_courseHoles", "GolfCourseHoles", "choice",
  "golf_driving_range", "DrivingRange", "yes_no",
  
  "basketball_court", "BasketballCourt", "yes_no",
  "basketball_count", "BasketballCount", "count",
  
  "multipurpose_court", "MultipurposeCourt", "yes_no",
  "multipurpose_count", "MultipurposeCount", "count",
  
  "pickleball_courts", "PickleballCourt", "yes_no",
  "pickleball_count", "PickleballCount", "count",
  
  "tennis_courts", "TennisCourt", "yes_no",
  "tennis_count", "TennisCount", "count",
  
  "sand_volleyball", "VolleyballSand", "yes_no",
  "volleyballsand_count", "VolleyballSandCount", "count",
  
  "volleyball_other", "VolleyballOther", "yes_no",
  "volleyballother_count", "VolleyballOtherCount", "count",
  
  "batting_cage", "BatCage", "yes_no",
  "BatCageCount", "BatCageCount", "count",
  
  "diamond_athletic_field", "DiamondField", "yes_no",
  "diamond_field_count", "DiamondFieldCount", "count",
  
  "inclusive_diamond_field", "InclusiveDiamond", "yes_no",
  "includiamond_count", "InclusiveDiamondCount", "count",
  
  "cricket_field", "CricketField", "yes_no",
  "cricket_count", "CricketCount", "count",
  
  "rectangular_field", "RectangularField", "yes_no",
  "rectangle_count", "RectangularFieldCount", "count",
  "running_track", "RunningTrack", "yes_no",
  
  "amphitheater_stage", "Amphitheater", "yes_no",
  "dog_park", "DogPark", "yes_no",
  "foodTruck_infrastructure", "FoodTruck", "yes_no",
  
  "lawn_games", "YardGames", "yes_no",
  "lawnGame_selection", "YardGameSelect", "multi_select",
  "lawnGame_selection_other", "YardGameSelect_other", "text",
  
  "table_games", "TableGames", "yes_no",
  "tableGame_selection", "table_games_selection", "multi_select",
  "tableGame_selection_other", "table_games_selection_other", "text",
  
  "MiniGolf", "MiniGolf", "yes_no",
  "Carousel", "Carousel", "yes_no",
  "miniature_train", "MiniTrain", "yes_no",
  
  "playground", "Playground", "yes_no",
  "playground_count", "PlaygroundCount", "count",
  "playground_universal", "InclusivePlayground", "yes_no",
  "nature_playscape", "NaturePlayscape", "yes_no",
  
  "picnic_area", "PicnicArea", "yes_no",
  "picnic_shelter", "PicnicShelter", "yes_no",
  "picnic_shelter_count", "PicnicShelterCount", "count",
  
  "equestrian_center", "Equestrian", "yes_no",
  "equestrian_or_bridle_trails", "EquestrianTrail", "yes_no",
  "total_miles_of_equestrian_trail", "equestrian_mileage", "count",
  
  "equestrian_campsites", "EquestCampsite", "yes_no",
  "number_of_campsites", "EquestCampsite_Count", "count",
  
  "cabins", "Cabins", "yes_no",
  "number_of_cabins", "CabinCount", "count",
  
  "primitive_campsites", "PrimitiveCamp", "yes_no",
  "primitiveSite_Count", "PrimitiveSiteCount", "count",
  
  "rv_campsites", "RV_camping", "yes_no",
  "RVsite_Count", "RvSiteCount", "count",
  
  "tent_campsites", "Tent_camping", "yes_no",
  "tentSites_Count", "TentSiteCount", "count",
  
  "freshwater_fishing", "Fishing", "yes_no",
  "FreshFishType", "FreshFishType", "multi_select",
  
  "saltwater_fishing", "Fishing", "yes_no",
  "SaltFishType", "SaltFishType", "multi_select",
  
  "boat_ramp", "BoatRamp", "yes_no",
  "RampCount", "BoatRampCount", "count",
  "boating_allowed", "BoatingAllowed", "multi_select",
  
  "paddle_access", "BluewayPaddle", "yes_no",
  "boat_rentals", "BoatRental", "yes_no",
  
  "terra_trails", "Trails", "yes_no",
  "TerraTrail_Mi", "terra_trail_mileage", "count",
  "TrailUse_Allow", "TrailUseAllowed", "multi_select",
  
  "mountain_bike_trails", "MountainBike", "yes_no",
  "total_miles_of_mountain_bike_tr", "mountain_bike_mileage", "count",
  
  "water_based_trails", "WaterTrail", "yes_no",
  "WaterTrail_Mi", "water_trail_mileage", "count",
  
  "other_facilities", "Other", "text"
)


# Fields intentionally added to the master schema

new_master_fields = c(
  "WildlifeObservation",
  "DiscCourseCount",
  "GolfCourseHoles",
  "RectangularField",
  "RectangularFieldCount",
  "YardGameSelect_other",
  "InclusivePlayground",
  "NaturePlayscape",
  "PicnicArea",
  "EquestCampsite",
  "EquestCampsite_Count",
  "FreshFishType",
  "SaltFishType",
  "BoatingAllowed",
  "BoatRental",
  "terra_trail_mileage",
  "TrailUseAllowed",
  "WaterTrail",
  "water_trail_mileage"
)


# Survey fields intentionally preserved only in the raw archive

survey_ignore = c(
  "objectid",
  "globalid",
  "creationdate",
  "creator",
  "editdate",
  "editor",
  "merge_src",
  "region",
  
  "name_completing_survey",
  "your_title_position",
  "contact_info_email_address",
  "contact_me_about_data",
  
  "park_name",
  "park_name_copy",
  "park_address",
  "agency",
  "managing_agency_copy",
  "is_the_park_shown_correctly_on",
  "boundary_errors",
  
  "park_entrance_use_fees_.*",
  "park_facility_access_.*",
  
  "terratrail_miles",
  "watertrail_miles"
)


# =============================================================================
# PART 5: VALIDATE MAPPING AND CONDITION CHILD FIELDS
# =============================================================================

map_problem = amenity_map |>
  mutate(
    mixed_type = n_distinct(value_type) > 1,
    .by = master_field
  ) |>
  mutate(
    bad_type = !value_type %in% c(
      "yes_no",
      "count",
      "choice",
      "multi_select",
      "text"
    ),
    
    dup_survey =
      duplicated(survey_field) |
      duplicated(survey_field, fromLast = TRUE),
    
    no_survey =
      !survey_field %in% names(survey_data),
    
    no_master =
      !master_field %in% c(
        names(amenities),
        new_master_fields
      ),
    
    count_name =
      value_type == "count" &
      !str_detect(
        master_field,
        regex(num_pattern, ignore_case = TRUE)
      )
  ) |>
  filter(
    mixed_type |
      bad_type |
      dup_survey |
      no_survey |
      no_master |
      count_name
  )


stray_new = setdiff(
  new_master_fields,
  amenity_map$master_field
)


if (nrow(map_problem) > 0 || length(stray_new) > 0) {
  
  print(map_problem, n = Inf)
  
  if (length(stray_new) > 0) {
    cat(
      "new_master_fields not used in amenity_map:",
      paste(stray_new, collapse = ", "),
      "\n"
    )
  }
  
  stop("Fix amenity_map or new_master_fields before running.")
}


# Child questions are valid only when the parent question is Yes

child_parent = c(
  number_of_disc_courses = "disc_golf",
  total_number_of_holes = "disc_golf",
  golf_courseHoles = "golf_course",
  
  basketball_count = "basketball_court",
  multipurpose_count = "multipurpose_court",
  pickleball_count = "pickleball_courts",
  tennis_count = "tennis_courts",
  volleyballsand_count = "sand_volleyball",
  volleyballother_count = "volleyball_other",
  BatCageCount = "batting_cage",
  
  diamond_field_count = "diamond_athletic_field",
  includiamond_count = "inclusive_diamond_field",
  cricket_count = "cricket_field",
  rectangle_count = "rectangular_field",
  
  lawnGame_selection = "lawn_games",
  lawnGame_selection_other = "lawn_games",
  tableGame_selection = "table_games",
  tableGame_selection_other = "table_games",
  
  playground_count = "playground",
  playground_universal = "playground",
  picnic_shelter_count = "picnic_shelter",
  
  total_miles_of_equestrian_trail = "equestrian_or_bridle_trails",
  number_of_campsites = "equestrian_campsites",
  
  number_of_cabins = "cabins",
  primitiveSite_Count = "primitive_campsites",
  RVsite_Count = "rv_campsites",
  tentSites_Count = "tent_campsites",
  
  FreshFishType = "freshwater_fishing",
  SaltFishType = "saltwater_fishing",
  
  RampCount = "boat_ramp",
  boating_allowed = "boat_ramp",
  
  TerraTrail_Mi = "terra_trails",
  TrailUse_Allow = "terra_trails",
  
  total_miles_of_mountain_bike_tr = "mountain_bike_trails",
  WaterTrail_Mi = "water_based_trails"
)


for (child in names(child_parent)) {
  
  parent = child_parent[[child]]
  parent_yes = is_yes(survey_data[[parent]])
  
  survey_data[[child]][!parent_yes] = NA
}


# Reverse completeness check

ignore_regex = paste0(
  "^(",
  paste(survey_ignore, collapse = "|"),
  ")$"
)

unmapped_fields = survey_data |>
  st_drop_geometry() |>
  select(
    !any_of(amenity_map$survey_field) &
      !matches(ignore_regex)
  ) |>
  select(
    where(
      \(x) any(
        !is.na(x) &
          str_squish(as.character(x)) != ""
      )
    )
  ) |>
  names()


if (length(unmapped_fields) > 0) {
  
  warning(
    "Survey123 fields with data but no mapping: ",
    paste(unmapped_fields, collapse = ", "),
    call. = FALSE
  )
}


# =============================================================================
# PART 6: MATCH SURVEY RESPONSES TO PARKS
# =============================================================================

survey_matched = match_survey_to_master(
  survey_data = survey_data,
  master_polygons = boundaries
)


unmatched = survey_matched |>
  st_drop_geometry() |>
  filter(match_status != "matched") |>
  distinct(
    survey_row_id,
    region,
    match_status,
    match_count,
    pick(
      any_of(
        c(
          "objectid",
          "globalid",
          "Park_Name",
          "park_name_copy",
          "park_address"
        )
      )
    )
  )


if (nrow(unmatched) > 0) {
  
  cat(
    "\nResponses not matched to exactly one park:\n"
  )
  
  print(
    head(
      unmatched,
      print_rows
    )
  )
}


# =============================================================================
# PART 7: SUMMARIZE RESPONSES
# =============================================================================

matched = survey_matched |>
  st_drop_geometry() |>
  filter(match_status == "matched")


survey_summary = matched |>
  select(
    park_id,
    all_of(amenity_map$survey_field)
  ) |>
  mutate(
    across(
      !park_id,
      as.character
    )
  ) |>
  pivot_longer(
    !park_id,
    names_to = "survey_field",
    values_to = "value"
  ) |>
  inner_join(
    amenity_map,
    by = "survey_field"
  ) |>
  summarise(
    incoming = combine_values(
      value,
      value_type[1]
    ),
    .by = c(
      park_id,
      master_field,
      value_type
    )
  ) |>
  filter(!is.na(incoming))


response_count = matched |>
  count(
    park_id,
    name = "responses"
  )


cat(
  "\nParks with at least one matched response:",
  nrow(response_count),
  "\nResponses per matched park:\n"
)

print(
  table(
    response_count$responses
  )
)


parks_not_in_master = setdiff(
  response_count$park_id,
  amenities$park_id
)


if (length(parks_not_in_master) > 0) {
  
  cat(
    "\nMatched parks missing from amenity master:",
    length(parks_not_in_master),
    "\n"
  )
}


survey_summary = survey_summary |>
  filter(
    park_id %in% amenities$park_id
  )


# =============================================================================
# PART 8: UPDATE MASTER
# =============================================================================

amenities_updated = amenities

count_masters = amenity_map |>
  filter(value_type == "count") |>
  pull(master_field) |>
  unique()


for (f in setdiff(new_master_fields, names(amenities))) {
  
  amenities_updated[[f]] =
    if (f %in% count_masters) {
      NA_real_
    } else {
      NA_character_
    }
}


changelog = list()


for (s in split(survey_summary, survey_summary$master_field)) {
  
  f = s$master_field[1]
  type = s$value_type[1]
  
  row = match(
    s$park_id,
    amenities_updated$park_id
  )
  
  current = amenities_updated[[f]][row]
  
  
  new = switch(
    type,
    
    yes_no = if_else(
      s$incoming == "Yes",
      "Yes",
      as.character(current)
    ),
    
    count = as.numeric(
      s$incoming
    ),
    
    choice = map2_chr(
      current,
      s$incoming,
      \(a, b) union_values(c(a, b))
    ),
    
    multi_select = map2_chr(
      current,
      s$incoming,
      \(a, b) union_values(c(a, b))
    ),
    
    text = map2_chr(
      current,
      s$incoming,
      \(a, b) union_text(c(a, b))
    )
  )
  
  
  changed = which(
    !is.na(new) &
      (
        is.na(current) |
          as.character(current) != as.character(new)
      )
  )
  
  
  if (length(changed) == 0) next
  
  
  amenities_updated[[f]][row[changed]] =
    new[changed]
  
  
  changelog[[f]] = tibble(
    park_id = s$park_id[changed],
    
    MA_NAME = as.character(
      amenities_updated$MA_NAME[row[changed]]
    ),
    
    master_field = f,
    value_type = type,
    
    old_value = as.character(
      current[changed]
    ),
    
    new_value = as.character(
      new[changed]
    )
  )
}


changelog = bind_rows(changelog)


# =============================================================================
# PART 9: REVIEW RESULTS
# =============================================================================

region_summary = survey_matched |>
  st_drop_geometry() |>
  distinct(
    survey_row_id,
    region,
    match_status
  ) |>
  count(
    region,
    match_status
  ) |>
  pivot_wider(
    names_from = match_status,
    values_from = n,
    values_fill = 0
  )


cat("\nMatch status by region:\n")
print(region_summary)


cat(
  "\nNew master columns created:",
  sum(!new_master_fields %in% names(amenities)),
  "\nAmenity cells updated:",
  nrow(changelog),
  "\n"
)


if (nrow(changelog) > 0) {
  
  cat("\nUpdates by column:\n")
  
  print(
    count(
      changelog,
      value_type,
      master_field,
      sort = TRUE
    ),
    n = Inf
  )
  
  
  count_drops = changelog |>
    filter(
      value_type == "count",
      !is.na(old_value)
    ) |>
    filter(
      as.numeric(new_value) <
        as.numeric(old_value)
    )
  
  
  if (nrow(count_drops) > 0) {
    
    cat(
      "\nCounts revised downward:",
      nrow(count_drops),
      "\n"
    )
    
    print(
      head(
        count_drops,
        print_rows
      )
    )
  }
  
  
  cat("\nFirst changed cells:\n")
  
  print(
    head(
      changelog,
      print_rows
    )
  )
}


# =============================================================================
# PART 10: FINAL QA AND WRITE
# =============================================================================

stopifnot(
  !anyNA(amenities_updated$park_id),
  !anyDuplicated(amenities_updated$park_id),
  nrow(amenities_updated) == nrow(amenities),
  setequal(amenities_updated$park_id, boundaries$park_id),
  all(names(amenities) %in% names(amenities_updated)),
  !file.exists(output_path)
)


write_xlsx(
  amenities_updated,
  output_path
)


parks_changed =
  if (nrow(changelog) == 0) {
    0
  } else {
    n_distinct(changelog$park_id)
  }


message(
  "Master Park Amenity Dataset written: ",
  output_path
)

message(
  "Parks in table: ",
  nrow(amenities_updated),
  " | parks changed: ",
  parks_changed,
  " | cells changed: ",
  nrow(changelog)
)

