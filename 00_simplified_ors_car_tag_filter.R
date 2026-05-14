library(osmdata)
library(sf)
library(tidyverse)

set_overpass_url("https://overpass.kumi.systems/api/interpreter")

place_name <- "Wake County, North Carolina"

road_types <- c(
  "motorway","motorway_link","motorroad","trunk","trunk_link",
  "primary","primary_link","secondary","secondary_link",
  "tertiary","tertiary_link","unclassified","residential",
  "living_street","service","road","track"
)

intended <- c("yes","permissive","destination")

get_first <- function(x) coalesce(x$motorcar, x$motor_vehicle, x$vehicle, x$access)

roads <- opq(place_name, timeout = 180) %>%
  add_osm_feature("highway", road_types) %>%
  osmdata_sf() %>%
  pluck("osm_lines")


roads_filtered <- roads %>%
  mutate(
    impassable = if (!"impassable" %in% names(.)) NA else impassable,
    smoothness = if (!"smoothness" %in% names(.)) NA else smoothness,
    status = if(!"status" %in% names(.)) NA else status,
    tracktype = if (!"tracktype" %in% names(.)) NA else tracktype,
    access_val = get_first(.),
    track_num = readr::parse_number(tracktype)
  ) %>%
  filter(
    # ORS rule: reject if highway != wayTypesWithDefaultSpeed
    highway %in% road_types,
    
    # ORS rule: reject water crossings
    highway != "ford",
    
    # ORS rule: highway = track AND tracktype > grade3
    !(highway == "track" & !is.na(track_num) & track_num > 3),
    
    # ORS rule: impassable = yes OR [status, smoothness] = impassable
    is.na(impassable) | impassable != "yes",
    is.na(smoothness) | smoothness != "impassable",
    is.na(status) | status != "impassable",
    
    # ORS rule: firstValue = intendedValues
    is.na(access_val) | access_val %in% intended
  )

roads_filtered <- roads_filtered %>% select(osm_id, name, geometry)

st_write(roads_filtered, "./Data/Wake/wake_roads_ors.geojson", delete_dsn = TRUE)
