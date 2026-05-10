library(sf)
library(dplyr)
library(purrr)
library(uuid)
library(openrouteservice)

pts <- st_read("./Data/Wake/wake_access_points.geojson", quiet = TRUE) |>
  st_transform(4326)

get_iso_ors <- function(lon, lat, range_sec = 600) {
  ors_isochrones(
    locations = matrix(c(lon, lat), ncol = 2),
    profile = "driving-car",
    range = range_sec,
    output = "sf"
  )
}

safe_iso <- possibly(get_iso_ors, otherwise = NULL)

# --------------------------------------------------
# Resume from checkpoint if exists
# --------------------------------------------------

checkpoint_path <- "./Data/Wake/wake_iso10min_checkpoint.geojson"

if (file.exists(checkpoint_path)) {
  iso10_done <- st_read(checkpoint_path, quiet = TRUE)
  completed_ids <- iso10_done$PointID
  message(sprintf("Resuming: %d / %d completed", length(completed_ids), nrow(pts)))
} else {
  iso10_done <- NULL
  completed_ids <- character(0)
}

pts_remaining <- pts |>
  filter(!PointID %in% completed_ids)


message(sprintf("Remaining: %d points", nrow(pts_remaining)))

# --------------------------------------------------
# Run with delay; save checkpoint every 50 points
# --------------------------------------------------

iso10_list <- vector("list", nrow(pts_remaining))
failed_points <- character(0)

collect_iso <- function(done_sf, new_list) {
  new_sf_list <- compact(new_list)
  
  if (length(new_sf_list) == 0) {
    if (is.null(done_sf)) {
      return(pts_remaining[0, ] |> select(PointID, SiteID, source, geometry) |> mutate(IsoID = character()))
    }
    return(done_sf |> select(IsoID, PointID, SiteID, source, geometry))
  }
  
  bind_rows(done_sf, bind_rows(new_sf_list)) |>
    select(IsoID, PointID, SiteID, source, geometry)
}

for (i in seq_len(nrow(pts_remaining))) {
  if (i %% 50 == 0 || i == 1) message(sprintf("[%d / %d] %.1f%%", i, nrow(pts_remaining), i / nrow(pts_remaining) * 100))
  
  Sys.sleep(1.5)
  
  xy <- st_coordinates(pts_remaining[i, ])
  result <- safe_iso(xy[1], xy[2], 600)
  
  if (is.null(result)) {
    failed_points <- c(failed_points, pts_remaining$PointID[i])
  } else {
    iso10_list[[i]] <- result |>
      mutate(
        IsoID   = UUIDgenerate(),
        PointID = pts_remaining$PointID[i],
        SiteID  = pts_remaining$SiteID[i],
        source  = pts_remaining$source[i]
      )
  }
  
  # Save checkpoint every 50 points
  if (i %% 50 == 0) {
    iso10_so_far <- collect_iso(iso10_done, iso10_list)
    st_write(iso10_so_far, checkpoint_path, delete_dsn = TRUE, quiet = TRUE)
    message(sprintf("Checkpoint saved: %d isochrones", nrow(iso10_so_far)))
  }
}

# --------------------------------------------------
# Final checkpoint save
# --------------------------------------------------

iso10 <- collect_iso(iso10_done, iso10_list)

st_write(iso10, checkpoint_path, delete_dsn = TRUE, quiet = TRUE)
message(sprintf("Checkpoint saved: %d isochrones", nrow(iso10)))

if (length(failed_points) > 0) {
  message(sprintf("Failed points: %d", length(failed_points)))
}

# --------------------------------------------------
# Final output (run after all points completed)
# --------------------------------------------------

# iso10_final <- iso10 |>
#   left_join(parks |> st_drop_geometry(), by = "SiteID")
# 
# st_write(iso10_final, "./Data/Wake/wake_iso10min.geojson", delete_dsn = TRUE)
