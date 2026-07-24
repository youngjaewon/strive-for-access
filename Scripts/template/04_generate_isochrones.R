# =============================================================================
# 04a_generate_isochrones.R
# -----------------------------------------------------------------------------
# Strive for Access (SFA) - Service Area pipeline
#
# Purpose:
#   Generate a 10 minute driving time isochrone for every access point in the
#   Master Park Access Point Dataset, using a local openrouteservice instance,
#   and write them as one statewide file keyed by access_point_id.
#
# Prerequisite
#   A local ORS server built from the same Geofabrik NC extract as 03c:
#     docker run -d --name ors-nc -p 8080:8082 \
#       -v $(pwd)/nc.osm.pbf:/home/ors/files/nc.osm.pbf \
#       -e REBUILD_GRAPHS=True openrouteservice/openrouteservice:latest
#   Ready when /ors/v2/health returns status ready. Using the same extract
#   keeps the isochrones consistent with the ORS filtered road network that
#   placed the access points.
#
# How it runs
#   The self-hosted ORS default caps isochrone requests at 2 locations, so the
#   points go in batches of 2 (about 5700 requests, several minutes against
#   localhost). Each batch is appended to a checkpoint file as soon as it
#   returns, so an interrupted run resumes where it stopped instead of
#   starting over.
#
# Output
#   service_areas/isochrones_10min_YYYYMMDD.gpkg
#   One polygon per access point.
#   Primary key: service_area_id (12 character hex, same format as park_id)
#   Foreign keys: access_point_id, park_id
# =============================================================================

# --- Packages ----------------------------------------------------------------

library(tidyverse)
library(sf)
library(httr2)


# =============================================================================
# CONFIG (check paths, then run)
# =============================================================================

root <- "/Users/ywon3/Library/CloudStorage/Dropbox/03_Strive for Access/Data"

# Input and output files. Update before each run.
access_points_path <- file.path(root, "master", "access_points", "access_points_20260724.gpkg")
output_path        <- file.path(root, "master", "service_areas", "isochrones_10min_20260724.gpkg")

# Checkpoint written batch by batch; delete it to force a clean rerun.
checkpoint_path <- file.path(root, "master", "service_areas", "isochrones_10min_checkpoint.gpkg")

ors_url    <- "http://localhost:8080/ors/v2/isochrones/driving-car"
range_sec  <- 600     # 10 minutes of driving time
batch_size <- 2       # self-hosted ORS default maximum locations per request
pause_sec  <- 0       # delay between requests; keep 0 for a local server


# =============================================================================
# PART 1: HELPERS
# =============================================================================

library(ids)

# 12 character hexadecimal identifiers, the same format as park_id and
# access_point_id.
generate_hex_ids <- function(n, existing_ids = character()) {
  if (n == 0) return(character())
  out <- character()
  while (length(out) < n) {
    cand <- unique(ids::random_id(n = n - length(out), bytes = 6))
    out <- c(out, cand[!cand %in% existing_ids & !cand %in% out])
  }
  out
}

standardize_geometry_name <- function(x) {
  g <- attr(x, "sf_column")
  if (is.null(g)) stop("The object has no active sf geometry column.")
  if (g != "geometry") { names(x)[names(x) == g] <- "geometry"; attr(x, "sf_column") <- "geometry" }
  x
}

# One request for up to 5 points. Returns an sf with one polygon per input
# point (ORS group_index maps each polygon back to its location), or NULL on
# failure so the caller can log and continue.
fetch_isochrones <- function(coords, ids) {
  
  body <- list(
    locations = coords,          # list of c(lon, lat)
    range     = list(range_sec),
    smoothing = 0
  )
  
  resp <- tryCatch(
    request(ors_url) |>
      req_body_json(body) |>
      req_timeout(60) |>
      req_perform(),
    error = function(e) NULL
  )
  
  if (is.null(resp) || resp_status(resp) != 200) return(NULL)
  
  iso <- tryCatch(
    {
      tmp <- tempfile(fileext = ".geojson")
      writeLines(resp_body_string(resp), tmp)
      out <- read_sf(tmp, quiet = TRUE)
      unlink(tmp)
      out
    },
    error = function(e) NULL
  )
  
  if (is.null(iso) || nrow(iso) == 0) return(NULL)
  
  iso |>
    standardize_geometry_name() |>
    transmute(access_point_id = ids[group_index + 1])
}


# =============================================================================
# PART 2: LOAD ACCESS POINTS AND CHECK THE SERVER
# =============================================================================

stopifnot(file.exists(access_points_path))

health <- tryCatch(
  request("http://localhost:8080/ors/v2/health") |> req_perform() |> resp_body_json(),
  error = function(e) NULL
)
if (is.null(health) || !identical(health$status, "ready")) {
  stop("Local ORS server is not ready at localhost:8080. ",
       "Start the docker container and wait for /ors/v2/health to report ready.")
}

message("Reading access points: ", access_points_path)
access_points <- st_read(access_points_path, quiet = TRUE) |>
  standardize_geometry_name() |>
  st_transform(4326)

stopifnot(all(c("access_point_id", "park_id") %in% names(access_points)))
stopifnot(!any(duplicated(access_points$access_point_id)))

# Resume support: skip points already present in the checkpoint
done <- if (file.exists(checkpoint_path)) {
  st_read(checkpoint_path, quiet = TRUE) |> standardize_geometry_name()
} else {
  NULL
}

todo <- access_points |>
  filter(!access_point_id %in% (if (is.null(done)) character() else done$access_point_id))

cat("\nAccess points total:", nrow(access_points),
    "\nAlready in checkpoint:", if (is.null(done)) 0 else nrow(done),
    "\nTo process:", nrow(todo), "\n")


# =============================================================================
# PART 3: BATCHED REQUESTS WITH CHECKPOINTING
# =============================================================================

if (nrow(todo) > 0) {
  
  coords_all <- st_coordinates(todo)
  batch_id   <- ceiling(seq_len(nrow(todo)) / batch_size)
  n_batches  <- max(batch_id)
  failed_ids <- character()
  
  t_start <- Sys.time()
  
  for (b in seq_len(n_batches)) {
    
    rows   <- which(batch_id == b)
    coords <- lapply(rows, \(r) c(coords_all[r, "X"], coords_all[r, "Y"]))
    ids    <- todo$access_point_id[rows]
    
    iso <- fetch_isochrones(coords, ids)
    
    if (is.null(iso)) {
      failed_ids <- c(failed_ids, ids)
    } else {
      st_write(iso, checkpoint_path, layer = "isochrones",
               append = file.exists(checkpoint_path), quiet = TRUE)
    }
    
    if (b %% 100 == 0 || b == n_batches) {
      elapsed <- as.numeric(difftime(Sys.time(), t_start, units = "mins"))
      message(sprintf("Batch %d/%d (%.1f min elapsed, %d failed points so far)",
                      b, n_batches, elapsed, length(failed_ids)))
    }
    
    if (pause_sec > 0) Sys.sleep(pause_sec)
  }
  
  if (length(failed_ids) > 0) {
    warning(length(failed_ids), " access points returned no isochrone. ",
            "Their ids are in failed_ids; rerunning the script retries them ",
            "automatically via the checkpoint.")
  }
}


# =============================================================================
# PART 4: ASSEMBLE, VALIDATE, AND WRITE
# =============================================================================

isochrones <- st_read(checkpoint_path, quiet = TRUE) |>
  standardize_geometry_name() |>
  distinct(access_point_id, .keep_all = TRUE) |>
  left_join(
    access_points |> st_drop_geometry() |> select(access_point_id, park_id, any_of("MA_NAME")),
    by = "access_point_id"
  ) |>
  st_make_valid() |>
  mutate(
    service_area_id = generate_hex_ids(n()),
    .before = 1
  )

missing_iso <- setdiff(access_points$access_point_id, isochrones$access_point_id)

cat("\nIsochrones built:", nrow(isochrones), "of", nrow(access_points), "access points\n")

if (length(missing_iso) > 0) {
  cat(length(missing_iso), "access points have no isochrone",
      "(typically points ORS cannot route from, e.g. islands). Ids:\n")
  print(head(missing_iso, 25))
}

stopifnot(!any(duplicated(isochrones$access_point_id)))
stopifnot(!any(duplicated(isochrones$service_area_id)))
stopifnot(!any(st_is_empty(isochrones)))

if (!dir.exists(dirname(output_path))) dir.create(dirname(output_path), recursive = TRUE)
stopifnot(!file.exists(output_path))

st_write(isochrones, output_path, layer = "isochrones", delete_dsn = TRUE, quiet = TRUE)

message("Isochrone dataset written: ", output_path)
message(nrow(isochrones), " polygons (10 min driving, range ", range_sec, " s). ",
        "The checkpoint file can be deleted once this output is confirmed.")