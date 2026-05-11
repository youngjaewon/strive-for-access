library(sf)
library(dplyr)
library(osmdata)
library(tigris)
library(tmap)
library(uuid)

# --------------------------------------------------
# 1 Load data
# --------------------------------------------------

parks_all <- st_read("./Data/RecLandsAll.geojson", quiet = TRUE)
roads <- st_read("./Data/Wake/wake_roads_ors.geojson", quiet = TRUE) |>
  st_transform(26917)

wake <- counties("NC", cb = TRUE) |>
  filter(NAME == "Wake")

parks <- parks_all |>
  st_transform(st_crs(wake)) |>
  st_intersection(wake) |>
  st_transform(26917) |>
  mutate(SiteID = UUIDgenerate(n = n()))

st_write(parks, "./Data/Wake/wake_polygons.geojson", delete_dsn = TRUE)

# --------------------------------------------------
# 2 Load existing public access points
# --------------------------------------------------

public_access_raw <- st_read("./Data/Parks_in_Wake_County.geojson", quiet = TRUE) |>
  st_transform(26917)

# Assign SiteID by nearest park polygon
idx <- st_nearest_feature(public_access_raw, parks)

public_access_pts <- public_access_raw |>
  mutate(
    PointID = UUIDgenerate(n = n()),
    SiteID  = parks$SiteID[idx],
    source  = "known_entrance"
  ) |>
  select(PointID, SiteID, source)

parks_remaining <- parks |>
  filter(!SiteID %in% public_access_pts$SiteID)

# --------------------------------------------------
# 3 Download OSM parking (amenity=parking only)
# --------------------------------------------------

bbox <- st_bbox(st_transform(parks, 4326))

osm_parking_amenity <- opq(bbox = bbox) |>
  add_osm_feature(key = "amenity", value = "parking") |>
  osmdata_sf()

# polygon parking
parking_poly <- bind_rows(
  osm_parking_amenity$osm_polygons,
  osm_parking_amenity$osm_multipolygons
) |>
  st_make_valid() |>
  filter(!st_is_empty(geometry)) |>
  distinct(osm_id, .keep_all = TRUE)

# point parking
parking_pts <- osm_parking_amenity$osm_points |>
  filter(!st_is_empty(geometry)) |>
  distinct(osm_id, .keep_all = TRUE)

# --------------------------------------------------
# 4 Convert parking polygons → centroid
# --------------------------------------------------

parking_access <- bind_rows(
  parking_poly |> st_centroid(),
  parking_pts
) |>
  st_transform(26917) |>
  filter(!st_is_empty(geometry))

# --------------------------------------------------
# 5 Parking inside remaining parks
# Cluster nearby points within 50m → one representative point per cluster
# --------------------------------------------------

parking_access_pts <- parking_access |>
  st_filter(parks_remaining) |>
  st_join(parks_remaining) |>
  mutate(source = "osm_parking") |>
  group_by(SiteID) |>
  group_modify(~ {
    coords <- st_coordinates(.x)
    if (nrow(coords) == 1) {
      .x |> slice(1)
    } else {
      clusters <- hclust(dist(coords), method = "complete")
      .x |>
        mutate(cluster = cutree(clusters, h = 50)) |>
        slice(1, .by = cluster) |>
        select(-cluster)
    }
  }) |>
  ungroup() |>
  st_sf(crs = 26917) |>
  filter(!st_is_empty(geometry)) |>
  mutate(
    PointID = UUIDgenerate(n = n()),
    source  = "osm_parking"
  ) |>
  select(PointID, SiteID, source)

parks_remaining2 <- parks_remaining |>
  filter(!SiteID %in% parking_access_pts$SiteID)

# --------------------------------------------------
# 6 Boundary intersection
# --------------------------------------------------

boundary_pts <- parks_remaining2 |>
  st_boundary() |>
  st_transform(26917) |>
  st_intersection(roads) |>
  st_collection_extract("POINT") |>
  st_cast("POINT") |>
  filter(!st_is_empty(geometry)) |>
  group_by(SiteID) |>
  group_modify(~ {
    coords <- st_coordinates(.x)
    if (nrow(coords) == 1) {
      .x |> slice(1)
    } else {
      clusters <- hclust(dist(coords), method = "complete")
      .x |>
        mutate(cluster = cutree(clusters, h = 50)) |>
        slice(1, .by = cluster) |>
        select(-cluster)
    }
  }) |>
  ungroup() |>
  mutate(
    PointID = UUIDgenerate(n = n()),
    source  = "boundary_intersection"
  ) |>
  select(PointID, SiteID, source)

parks_remaining3 <- parks_remaining2 |>
  filter(!SiteID %in% boundary_pts$SiteID)

# --------------------------------------------------
# 7 Snap to nearest road
# --------------------------------------------------

idx <- st_nearest_feature(parks_remaining3, roads)

snap_lines <- st_nearest_points(
  parks_remaining3,
  roads[idx, ],
  pairwise = TRUE
)

snap_pts <- st_sf(
  PointID       = UUIDgenerate(n = nrow(parks_remaining3)),
  SiteID        = parks_remaining3$SiteID,
  source        = "snapped",
  snap_distance = as.numeric(st_length(snap_lines)),
  geometry      = lwgeom::st_endpoint(snap_lines)
) |>
  filter(!st_is_empty(geometry))

# --------------------------------------------------
# 8 Combine access points
# --------------------------------------------------

access_points <- bind_rows(
  public_access_pts,
  parking_access_pts,
  boundary_pts,
  snap_pts
) |>
  filter(!st_is_empty(geometry))

# --------------------------------------------------
# 8.5 Interactive map
# --------------------------------------------------

tmap_mode("view")

tm_shape(parks) +
  tm_polygons(col = "lightgreen", alpha = 0.4, border.col = "darkgreen") +
  tm_shape(roads) +
  tm_lines(col = "gray60", lwd = 1) +
  tm_shape(access_points) +
  tm_symbols(
    col = "source",
    size = 0.3,
    palette = c(
      "known_entrance"        = "blue",
      "osm_parking"           = "purple",
      "boundary_intersection" = "red",
      "snapped"               = "orange"
    ),
    title.col = "Access Point Type"
  )

# --------------------------------------------------
# 9 Save result
# --------------------------------------------------

st_write(access_points, "./Data/Wake/wake_access_points.geojson", delete_dsn = TRUE)
