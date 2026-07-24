# ============================================================
# match_survey_to_master.R
#
# Match Survey123 responses to master park boundaries
#
# Purpose
#   Identify the master park (park_id) associated with each
#   Survey123 point.
#
# Matching rule
#   Survey123 points are matched to master park boundaries
#   using spatial intersection.
#
# Master boundaries
#   The Master Park Boundary Dataset uses park_id as its
#   primary key. If multiple rows share the same park_id,
#   they are dissolved before matching so that each park_id
#   represents one park.
#
# Match status
#   matched
#     The Survey123 point matches exactly one park_id.
#
#   unmatched
#     The Survey123 point does not match any park_id.
#
#   multiple_match
#     The Survey123 point matches more than one park_id.
# ============================================================

match_survey_to_master <- function(
    survey_data,
    master_polygons,
    verbose = TRUE
) {
  
  # --- Input checks ---------------------------------------------------------
  
  if (!inherits(survey_data, "sf")) {
    stop("survey_data must be an sf object.")
  }
  
  if (!inherits(master_polygons, "sf")) {
    stop("master_polygons must be an sf object.")
  }
  
  if (!"park_id" %in% names(master_polygons)) {
    stop("master_polygons must contain a park_id field.")
  }
  
  if (any(is.na(master_polygons$park_id))) {
    stop("master_polygons contains missing park_id values.")
  }
  
  if (is.na(sf::st_crs(survey_data))) {
    stop("survey_data does not have a coordinate reference system.")
  }
  
  if (is.na(sf::st_crs(master_polygons))) {
    stop("master_polygons does not have a coordinate reference system.")
  }
  
  # Park name field carried through for manual review, if available
  name_field <- if ("MA_NAME" %in% names(master_polygons)) "MA_NAME" else NULL
  
  output_fields <- c(
    "survey_row_id",
    "park_id",
    "master_park_name",
    "match_count",
    "match_status"
  )
  
  existing_output_fields <- intersect(
    output_fields,
    names(survey_data)
  )
  
  if (length(existing_output_fields) > 0) {
    stop(
      "survey_data already contains fields created by this function: ",
      paste(existing_output_fields, collapse = ", ")
    )
  }
  
  # --- Prepare master lookup ------------------------------------------------
  
  # Dissolve rows that share the same park_id (defensive; park_id should
  # already be unique per park).
  master_lookup <- master_polygons |>
    dplyr::select(
      park_id,
      dplyr::any_of(name_field)
    ) |>
    dplyr::group_by(park_id) |>
    dplyr::summarise(
      master_park_name = if (!is.null(name_field)) {
        dplyr::first(.data[[name_field]])
      } else {
        NA_character_
      },
      .groups = "drop"
    )
  
  # --- Match Survey123 points to parks --------------------------------------
  
  matched <- survey_data |>
    dplyr::mutate(
      survey_row_id = dplyr::row_number()
    ) |>
    sf::st_transform(
      sf::st_crs(master_polygons)
    ) |>
    sf::st_join(
      master_lookup,
      join = sf::st_intersects,
      left = TRUE
    )
  
  # Count the number of unique parks matched to each response.
  match_summary <- matched |>
    sf::st_drop_geometry() |>
    dplyr::group_by(survey_row_id) |>
    dplyr::summarise(
      match_count = dplyr::n_distinct(
        park_id[!is.na(park_id)]
      ),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      match_status = dplyr::case_when(
        match_count == 0L ~ "unmatched",
        match_count == 1L ~ "matched",
        TRUE ~ "multiple_match"
      )
    )
  
  matched <- matched |>
    dplyr::left_join(
      match_summary,
      by = "survey_row_id"
    ) |>
    dplyr::relocate(
      survey_row_id,
      match_status,
      match_count,
      park_id,
      master_park_name
    )
  
  if (verbose) {
    matched |>
      sf::st_drop_geometry() |>
      dplyr::distinct(
        survey_row_id,
        match_status
      ) |>
      dplyr::count(
        match_status,
        name = "response_count"
      ) |>
      print()
  }
  
  matched
}