# SFA Master Dataset Maintenance

This repository contains the R scripts and procedures used to maintain the master datasets for the **Strive for Access (SFA)** project.

The main purpose of this repository is ongoing maintenance. Use the **Maintenance Workflow** below when new data are added or existing records need to be updated.

## Master Datasets

The project maintains four linked master datasets.

| Dataset                      | Key                                             | Description                                      |
| ---------------------------- | ----------------------------------------------- | ------------------------------------------------ |
| **Park Boundaries**          | `park_id`                                       | Park polygons and core park information          |
| **Park Amenities**           | `park_id`                                       | One amenity record per park                      |
| **Park Access Points**       | `access_point_id`, `park_id`                    | One or more access points per park       |
| **Drive Time Service Areas** | `service_area_id`, `access_point_id`, `park_id` | Ten minute drive time area for each access point |

Existing IDs should be preserved when records are updated. New IDs should be assigned only to new records.

## Maintenance Workflow

Use the table below to determine what to update and which scripts to run.

Not every change affects all four master datasets. An amenity update may affect only the amenity data, while adding a new park may require updates across all four datasets.

| Scenario                                  | Input or condition                                                                              | Processing sequence                                                                                                                                                                                                   | Affected datasets                                   | Processing method                                                                                                                                                                                                                                                        |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **A. Park Inventory Change**              | New park polygon from an external source                                                        | `01_update_boundaries.R` → prepare amenity record → `03d_estimate_missing_access_points.R` → `04_generate_isochrones.R` → `05_create_exb_data.R`                                                                      | Boundaries, Amenities, Access Points, Service Areas | **Script + manual review.** Use `01_update_boundaries.R` to compare the new source with the boundary master and append new parks. Review new polygons before accepting the output. Amenity records can be prepared manually or through the appropriate amenity workflow. |
| **A. Park Inventory Change**              | Park identified through Survey123 but absent from the boundary master                           | Identify or obtain the correct polygon → add polygon in ArcGIS Pro or ArcGIS Online → assign new `park_id` → rerun relevant amenity and access point procedures → `04_generate_isochrones.R` → `05_create_exb_data.R` | Potentially all four master datasets                | **Manual + Script.** Review and add the park manually, then use the existing scripts for downstream updates. Previously unmatched Survey123 records should be checked again after the park is added.                                                                     |
| **A. Park Inventory Change**              | Existing park changes, including boundary, name, ownership, closure status, merger, or division | Edit boundary master → determine whether amenities or access points are affected → update affected records → regenerate service areas if needed → `05_create_exb_data.R`                                              | Depends on the change                               | **Manual + Script.** These changes usually require case specific review in ArcGIS Pro or ArcGIS Online. Preserve the existing `park_id` when the park remains the same project entity.                                                                                   |
| **B. Amenity Information Change**         | Polygon based external amenity source                                                           | Review source settings and field mapping → `02a_update_amenities_polygon.R` → review changes → `05_create_exb_data.R`                                                                                                 | Amenities                                           | **Automated + review.** Check source specific field mappings and spatial matching settings before running the script.                                                                                                                                                    |
| **B. Amenity Information Change**         | Point based external amenity source                                                             | Review source settings and field mapping → `02b_update_amenities_point.R` → review matches → `05_create_exb_data.R`                                                                                                   | Amenities                                           | **Automated + review.** Incoming points are matched to master parks. Review unmatched or ambiguous records.                                                                                                                                                              |
| **B. Amenity Information Change**         | New or updated Survey123 amenity responses                                                      | `02c_update_amenities_survey123.R` → review unmatched and multiple match records → `05_create_exb_data.R`                                                                                                             | Amenities                                           | **Automated + review.** Responses with one park match are processed automatically. Other records require review.                                                                                                                                                         |
| **B. Amenity Information Change**         | Manual correction to an existing amenity record                                                 | Confirm `park_id` → edit amenity master → QA/QC → `05_create_exb_data.R`                                                                                                                                              | Amenities                                           | **Manual + Script.** Small corrections can be made directly in the amenity master after confirming the correct park.                                                                                                                                                     |
| **C. Access Point Change**                | New external entrance, parking, or access point source                                          | Review source settings → `03a_update_external_access_points.R` → review matches and duplicates → `04_generate_isochrones.R` → `05_create_exb_data.R`                                                                  | Access Points, Service Areas                        | **Automated + review.** Incoming points are linked to parks and checked against existing access points before being added.                                                                                                                                               |
| **C. Access Point Change**                | Park has no verified access point                                                               | `03d_estimate_missing_access_points.R` → review estimated points → `04_generate_isochrones.R` → `05_create_exb_data.R`                                                                                                | Access Points, Service Areas                        | **Automated estimation + QA/QC.** Access points are estimated using OSM parking, road intersections, and road snapping.                                                                                                                                                  |
| **C. Access Point Change**                | Survey123 provides a usable park address or access location                                     | Confirm park match → geocode and validate location → add approved access point to master → `04_generate_isochrones.R` → `05_create_exb_data.R`                                                                        | Access Points, Service Areas                        | **Manual + existing geocoding logic.** `03b_geocode_survey123_access_points.R` contains the geocoding and validation logic used for Survey123 addresses.                                                                                                                 |
| **C. Access Point Change**                | Existing access point is corrected or removed                                                   | Confirm `access_point_id` and `park_id` → edit access point master → update the corresponding service area → `05_create_exb_data.R`                                                                                   | Access Points, Service Areas                        | **Manual + Script.** Access point changes should be followed by the corresponding service area update.                                                                                                                                                                   |
| **D. Downstream Refresh and Publication** | Amenity information changed but access points did not                                           | `05_create_exb_data.R`                                                                                                                                                                                                | Downstream application data                         | **Automated.** Service areas do not need to be regenerated.                                                                                                                                                                                                              |
| **D. Downstream Refresh and Publication** | Access points were added or changed                                                             | `04_generate_isochrones.R` → review service areas → `05_create_exb_data.R`                                                                                                                                            | Service Areas, downstream application data          | **Automated + review.** New or changed access points require updated service areas.                                                                                                                                                                                      |
| **D. Downstream Refresh and Publication** | Updated master datasets are ready for publication                                               | `05_create_exb_data.R` → update hosted feature layers → verify web maps → verify application                                                                                                                          | Hosted layers, web maps, application                | **Script + manual verification.** Confirm that ArcGIS Online content and the final application reflect the approved master datasets.                                                                                                                                     |

## Processing Scripts

| Script                                  | Purpose                                                          |
| --------------------------------------- | ---------------------------------------------------------------- |
| `01_update_boundaries.R`                | Add new park polygons while preserving existing `park_id` values |
| `02a_update_amenities_polygon.R`        | Update amenities from polygon sources                            |
| `02b_update_amenities_point.R`          | Update amenities from point sources                              |
| `02c_update_amenities_survey123.R`      | Update amenities from Survey123 responses                        |
| `03a_update_external_access_points.R`   | Add access points from external sources                          |
| `03b_geocode_survey123_access_points.R` | Geocode and validate Survey123 park addresses                    |
| `03c_build_road_network.R`              | Build or refresh statewide OSM roads and parking                 |
| `03d_estimate_missing_access_points.R`  | Estimate access points for parks without verified access points  |
| `04_generate_isochrones.R`              | Generate ten minute drive time service areas                     |
| `05_create_exb_data.R`                  | Prepare updated data for the Experience Builder application      |
| `match_survey_to_master.R`              | Match Survey123 points to master park polygons                   |

Run specific paths and settings are defined in the `CONFIG` section of each script.

## Data Locations and Versioning

```text
Data/
  master/
    boundaries/
      boundaries_YYYYMMDD.gpkg
    amenities/
      amenities_YYYYMMDD.xlsx
    access_points/
      access_points_YYYYMMDD.gpkg
    service_areas/
      isochrones_10min_YYYYMMDD.gpkg
  roads/
    nc_roads_ors.gpkg
    nc_parking.gpkg
    osm_cache/
```

Each update should create a new dated version rather than overwrite the previous approved master. If more than one version is created on the same day, use suffixes such as `_1` and `_2`.

Before running a script, confirm that its inputs point to the latest approved master datasets.

## Data Tracker

Every change to a master dataset should be recorded in the [SFA Data Tracker](https://docs.google.com/spreadsheets/d/1Mj7v2Q7nRTTEHCpM_62SxTbow9XXAHhui__ob46UsgI/edit?usp=sharing).

The Data Tracker is the update history for the master datasets. It records the date, dataset, source, script, input and output files, record counts, and notes about what changed.

Use the dated filename to find the corresponding update in the tracker. For example:

```text
boundaries_20260721.gpkg
amenities_20260723_2.xlsx
access_points_20260724.gpkg
isochrones_10min_20260724.gpkg
```

The Data Tracker should be used to determine what changes produced each version. The filename itself is only the version identifier.

For each accepted update:

1. Save the new versioned master dataset.
2. Record the update in the Data Tracker.
3. Record the script and source data used, when applicable.
4. Include the output filename and a short description of what changed.

## Notes

1. Review new polygons, ambiguous Survey123 matches, estimated access points, and other manually resolved records before using them in downstream steps.

2. Update only the datasets affected by the change. Amenity updates do not require new service areas. Access point changes do.

3. Keep IDs consistent across datasets. Amenity and access point records should reference valid `park_id` values, and service areas should reference valid `access_point_id` and `park_id` values.

4. Previously unmatched Survey123 records should be checked again when new park polygons are added.

5. Road data, access point estimation, and service area generation should use the same North Carolina OSM data snapshot when practical.

6. After publication, confirm that the hosted layers, web maps, and final application reflect the approved update.
