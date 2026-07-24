# =============================================================================
# 03d_estimate_missing_access_points.R
# -----------------------------------------------------------------------------
# Strive for Access (SFA) - Park Access Point Dataset pipeline
#
# Purpose:
#   Estimate access points for every park in the state that has none in the
#   master dataset, looping over all 100 counties, and append the estimated
#   points to the Master Park Access Point Dataset in one output file.
#
# Estimation hierarchy (applied per county, each park settled by the first
# step that produces a point for it):
#   1) osm_parking           : OSM amenity=parking inside the park
#                              (statewide file from 03c, clustered)
#   2) boundary_intersection : intersections of the park boundary with the
#                              ORS filtered road network (clustered)
#   3) snapped               : park polygon snapped to the nearest road
#                              (records snap distance)
#
# Flow (see SFA data flow diagram, Section 3: Park Access Point Dataset):
#   1) Data sources        : statewide OSM parking and ORS road network
#                            (both built once by 03c: roads/nc_roads_ors.gpkg
#                            and roads/nc_parking.gpkg)
#   2) Complete coverage   : estimate points where coverage is missing
#   3) Output              : access_points/access_points_YYYYMMDD.gpkg
#                            Primary key: access_point_id (12 character hex,
#                            same format as park_id)
#                            Foreign key: park_id
#
# How the loop works
#   Each county reads only its buffered window from the two statewide files
#   with wkt_filter, so every iteration stays as light as a single county run.
#   Parks crossing a county line are claimed by the first county that
#   processes them and skipped afterwards, so no park is estimated twice.
#   Results accumulate in memory and are written once at the end. A per county
#   log (county_log) records the funnel so odd counties can be revisited.
#
# Review objects left in the environment: county_log, estimated_all.
# The access point master is the only file written.
# =============================================================================

# --- Packages ----------------------------------------------------------------

library(tidyverse)
library(sf)
library(tigris)
library(tmap)
library(ids)
library(lwgeom)

options(tigris_use_cache = TRUE)


# =============================================================================
# CONFIG (check paths, then run)
# =============================================================================

root <- "/Users/ywon3/Library/CloudStorage/Dropbox/03_Strive for Access/Data"

# Input and output files. Update these three lines before each run. Adding a
# _1, _2 suffix keeps repeated runs on the same day from overwriting.
boundary_path <- file.path(root, "master", "boundaries", "boundaries_20260721.gpkg")
master_path   <- file.path(root, "master", "access_points", "access_points_20260723.gpkg")
output_path   <- file.path(root, "master", "access_points", "access_points_20260724.gpkg")

roads_path   <- file.path(root, "roads", "nc_roads_ors.gpkg")   # statewide, from 03c
parking_path <- file.path(root, "roads", "nc_parking.gpkg")     # statewide, from 03c

# Counties to process: NULL runs all 100, or a vector to run a subset,
# e.g. c("Wake", "Durham"). Useful for testing and for redoing odd counties.
counties_to_run <- NULL

state_name <- "NC"

# Source metadata recorded on appended rows
creator     <- "youngjaewon"
create_time <- as.POSIXct(paste(Sys.Date(), "12:00:00"), tz = "America/New_York")

crs_projected <- 32119   # NAD83 North Carolina, meters
cluster_dist  <- 50      # estimated points of one park within this distance (m)
# are reduced to one representative per cluster
county_buffer <- 1000    # roads are read this far (m) beyond the county line

# The final statewide QC map draws thousands of points; the road layer is
# omitted there to keep the browser responsive.
run_visual_check <- TRUE


# =============================================================================
# PART 1: HELPERS
# =============================================================================

# 12 character hexadecimal identifiers, the same format as park_id.
generate_access_point_ids <- function(n, existing_ids = character()) {
  if (n == 0) return(character())
  out <- character()
  while (length(out) < n) {
    cand <- unique(ids::random_id(n = n - length(out), bytes = 6))
    out <- c(out, cand[!cand %in% existing_ids & !cand %in% out])
  }
  out
}

# GPKG files come back with the geometry column named geom (the GDAL default),
# while objects built in R use geometry. Every read is normalized so that
# column references and bind_rows across the two never clash.
standardize_geometry_name <- function(x) {
  g <- attr(x, "sf_column")
  if (is.null(g)) stop("The object has no active sf geometry column.")
  if (g != "geometry") { names(x)[names(x) == g] <- "geometry"; attr(x, "sf_column") <- "geometry" }
  x
}

# Reduce nearby points of one park to one representative per cluster.
# Implemented with row indices rather than group_modify: dplyr grouping can
# strip the sf class from group data under some inputs, which made
# st_coordinates fail intermittently.
reduce_clusters <- function(pts, dist_m) {
  pts <- pts |> filter(!st_is_empty(geometry))
  if (nrow(pts) < 2) return(pts)
  
  coords <- st_coordinates(pts)[, c("X", "Y"), drop = FALSE]
  
  keep <- unlist(lapply(
    split(seq_len(nrow(pts)), pts$park_id),
    function(idx) {
      if (length(idx) == 1) return(idx)
      cl <- cutree(
        hclust(dist(coords[idx, , drop = FALSE]), method = "complete"),
        h = dist_m
      )
      idx[!duplicated(cl)]
    }
  ))
  
  pts[sort(keep), ]
}

# Estimate access points for the parks of one county. parks_missing must
# already exclude parks handled by earlier counties. Returns the estimated
# points and a one row log of the funnel.
estimate_county <- function(county_row, parks_missing) {
  
  county_proj <- st_transform(county_row, crs_projected)
  
  window_wkt <- county_proj |>
    st_buffer(county_buffer) |>
    st_transform(4326) |>
    st_geometry() |>
    st_as_text()
  
  roads <- st_read(roads_path, wkt_filter = window_wkt, quiet = TRUE) |>
    standardize_geometry_name() |>
    st_transform(crs_projected)
  
  parking <- st_read(parking_path, wkt_filter = window_wkt, quiet = TRUE) |>
    standardize_geometry_name() |>
    st_transform(crs_projected) |>
    filter(!st_is_empty(geometry))
  
  # Step 1: OSM parking inside parks
  step1 <- parking |>
    st_filter(parks_missing) |>
    st_join(parks_missing |> select(park_id)) |>
    reduce_clusters(cluster_dist) |>
    transmute(park_id, GIS_SRC = "osm_parking", snap_distance = NA_real_)
  
  remaining1 <- parks_missing |> filter(!park_id %in% step1$park_id)
  
  # Step 2: park boundary x road intersections
  step2 <- if (nrow(remaining1) > 0 && nrow(roads) > 0) {
    remaining1 |>
      select(park_id) |>
      st_boundary() |>
      st_intersection(roads) |>
      suppressWarnings() |>
      st_collection_extract("POINT") |>
      st_cast("POINT", warn = FALSE) |>
      filter(!st_is_empty(geometry)) |>
      reduce_clusters(cluster_dist) |>
      transmute(park_id, GIS_SRC = "boundary_intersection", snap_distance = NA_real_)
  } else {
    step1 |> slice(0)
  }
  
  remaining2 <- remaining1 |> filter(!park_id %in% step2$park_id)
  
  # Step 3: snap to nearest road
  step3 <- if (nrow(remaining2) > 0 && nrow(roads) > 0) {
    idx <- st_nearest_feature(remaining2, roads)
    snap_lines <- st_nearest_points(remaining2, roads[idx, ], pairwise = TRUE)
    st_sf(
      park_id       = remaining2$park_id,
      GIS_SRC       = "snapped",
      snap_distance = as.numeric(st_length(snap_lines)),
      geometry      = lwgeom::st_endpoint(snap_lines)
    ) |>
      filter(!st_is_empty(geometry))
  } else {
    step1 |> slice(0)
  }
  
  pts <- bind_rows(step1, step2, step3)
  
  log_row <- tibble(
    county          = county_row$NAME,
    parks_missing   = nrow(parks_missing),
    pts_parking     = nrow(step1),
    pts_boundary    = nrow(step2),
    pts_snapped     = nrow(step3),
    parks_covered   = n_distinct(pts$park_id),
    max_snap_dist_m = if (nrow(step3) > 0) round(max(step3$snap_distance)) else NA_real_
  )
  
  list(points = pts, log = log_row)
}


# =============================================================================
# PART 2: LOAD DATA
# =============================================================================

for (p in c(boundary_path, master_path, roads_path, parking_path)) {
  if (!file.exists(p)) stop("Input file not found: ", p)
}

message("Reading master boundaries: ", boundary_path)
boundaries <- st_read(boundary_path, quiet = TRUE) |>
  standardize_geometry_name() |>
  st_make_valid() |>
  st_transform(crs_projected)

message("Reading master access points: ", master_path)
master <- st_read(master_path, quiet = TRUE) |>
  standardize_geometry_name() |>
  st_transform(crs_projected)

stopifnot("park_id" %in% names(boundaries))
stopifnot(all(c("access_point_id", "park_id") %in% names(master)))

nc_counties <- counties(state = state_name, cb = TRUE, progress_bar = FALSE) |>
  arrange(NAME)

if (!is.null(counties_to_run)) {
  missing_names <- setdiff(counties_to_run, nc_counties$NAME)
  if (length(missing_names) > 0) stop("Unknown county name(s): ",
                                      paste(missing_names, collapse = ", "))
  nc_counties <- nc_counties |> filter(NAME %in% counties_to_run)
}

parks_no_ap <- boundaries |> filter(!park_id %in% master$park_id)

cat("\nMaster boundaries:          ", nrow(boundaries),
    "\nExisting access points:     ", nrow(master),
    "\nParks without access point: ", nrow(parks_no_ap),
    "\nCounties to process:        ", nrow(nc_counties), "\n")


# =============================================================================
# PART 3: COUNTY LOOP
# =============================================================================
# A park crossing a county line is claimed by the first county that reaches it
# (alphabetical order) and skipped afterwards via done_ids, so nothing is
# estimated twice. Each iteration reads only its window from the statewide
# files, keeping memory flat across the run.

results  <- list()
logs     <- list()
done_ids <- character()

t_start <- Sys.time()

for (i in seq_len(nrow(nc_counties))) {
  
  county_row <- nc_counties[i, ]
  
  parks_missing <- parks_no_ap |>
    filter(!park_id %in% done_ids) |>
    st_filter(st_transform(county_row, crs_projected), .predicate = st_intersects)
  
  if (nrow(parks_missing) == 0) {
    message(sprintf("[%3d/%d] %-12s no parks to estimate", i, nrow(nc_counties), county_row$NAME))
    next
  }
  
  res <- estimate_county(county_row, parks_missing)
  
  results[[county_row$NAME]] <- res$points
  logs[[county_row$NAME]]    <- res$log
  done_ids <- c(done_ids, unique(res$points$park_id))
  
  message(sprintf(
    "[%3d/%d] %-12s missing %4d | parking %4d, boundary %4d, snapped %4d | covered %4d",
    i, nrow(nc_counties), county_row$NAME,
    res$log$parks_missing, res$log$pts_parking,
    res$log$pts_boundary, res$log$pts_snapped, res$log$parks_covered
  ))
}

message("Loop finished in ",
        round(difftime(Sys.time(), t_start, units = "mins"), 1), " minutes.")

estimated_all <- bind_rows(results)
county_log    <- bind_rows(logs)


# =============================================================================
# PART 4: REVIEW RESULTS (console only)
# =============================================================================

cat("\nEstimated points by method:\n")
print(estimated_all |> st_drop_geometry() |> as_tibble() |> count(GIS_SRC))

cat("\nParks covered:",
    n_distinct(estimated_all$park_id), "of", nrow(parks_no_ap),
    "parks without an access point\n")

not_covered <- parks_no_ap |>
  filter(!park_id %in% estimated_all$park_id) |>
  st_drop_geometry() |>
  select(park_id, any_of("MA_NAME"))

if (nrow(not_covered) > 0) {
  cat("\nParks still without any point (", nrow(not_covered), ", review manually):\n", sep = "")
  print(head(not_covered, 25))
}

snap_all <- estimated_all |> filter(GIS_SRC == "snapped")
if (nrow(snap_all) > 0) {
  cat("\nSnap distance summary (m):\n")
  print(summary(snap_all$snap_distance))
  long_snaps <- snap_all |> filter(snap_distance > county_buffer)
  if (nrow(long_snaps) > 0) {
    cat(nrow(long_snaps), "snapped points exceed the", county_buffer,
        "m window buffer; their nearest true road may lie outside it.\n")
  }
}

cat("\nCounty funnel (county_log holds the full table):\n")
print(county_log, n = 15)


# =============================================================================
# PART 5: STANDARDIZE SCHEMA AND WRITE VERSIONED OUTPUT
# =============================================================================

new_selected <- estimated_all |>
  left_join(
    boundaries |> st_drop_geometry() |> select(park_id, MA_NAME),
    by = "park_id"
  ) |>
  transmute(
    access_point_id = generate_access_point_ids(n(), existing_ids = master$access_point_id),
    park_id,
    MA_NAME,
    GIS_SRC,
    snap_distance,
    Creator      = creator,
    CreationDate = create_time
  )

master_updated <- bind_rows(master, new_selected) |> st_transform(4326)

# Sanity checks before writing
stopifnot(!any(is.na(master_updated$access_point_id)))
stopifnot(!any(duplicated(master_updated$access_point_id)))
stopifnot(!any(is.na(master_updated$park_id)))
stopifnot(!file.exists(output_path))

st_write(master_updated, output_path, layer = "access_points", delete_dsn = TRUE, quiet = TRUE)

message("Master Park Access Point Dataset written: ", output_path)
message("Total access points: ", nrow(master_updated),
        " (", nrow(new_selected), " estimated points appended statewide)")


# =============================================================================
# PART 6: VISUAL QC (final master, statewide)
# =============================================================================
# Roads are left off the statewide map; thousands of points alone are already
# at the limit of what the interactive view handles comfortably.

if (run_visual_check) {
  tmap_mode("view")
  print(
    tm_shape(master_updated) +
      tm_symbols(
        fill = "GIS_SRC",
        size = 0.2,
        fill.scale = tm_scale_categorical(values = c(
          "Survey123"             = "#1565C0",
          "osm_parking"           = "#7B1FA2",
          "boundary_intersection" = "#D32F2F",
          "snapped"               = "#F57C00"
        )),
        fill.legend = tm_legend(title = "Access Point Source")
      )
  )
}