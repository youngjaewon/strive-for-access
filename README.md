# SFA Master Dataset Maintenance

This repository contains the R scripts and procedures used to maintain the versioned master datasets for the **Strive for Access (SFA)** project.

The repository is intended primarily for ongoing dataset maintenance. Use the **Conditional Maintenance Workflow** below to determine which datasets and scripts should be used when new information is received or an existing record changes.

## Master Datasets

The workflow maintains four linked master datasets.

| Dataset                      | Key                                             | Description                                           |
| ---------------------------- | ----------------------------------------------- | ----------------------------------------------------- |
| **Park Boundaries**          | `park_id`                                       | Authoritative park polygons and core park information |
| **Park Amenities**           | `park_id`                                       | One amenity record per park                           |
| **Park Access Points**       | `access_point_id`, `park_id`                    | One or more vehicle access points per park            |
| **Drive Time Service Areas** | `service_area_id`, `access_point_id`, `park_id` | Ten minute driving service area for each access point |

Existing identifiers should be preserved across versions. New identifiers should be assigned only to genuinely new records.

## Conditional Maintenance Workflow

Use the table below to determine the appropriate maintenance procedure when new information is received or an existing record needs to be changed.

Not every maintenance condition affects all four master datasets. For example, an amenity correction may require only an amenity update and downstream application refresh, while the addition of a new park may require changes to all four master datasets.

| Scenario                                  | Input or condition                                                                              | Processing sequence                                                                                                                                                                                                                                         | Affected datasets                                   | Processing method                                                                                                                                                                                                                                                                                                                           |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A. Park Inventory Change**              | New park polygon from an external source                                                        | `01_update_boundaries.R` → prepare amenity record → `03d_estimate_missing_access_points.R` → `04_generate_isochrones.R` → `05_create_exb_data.R`                                                                                                            | Boundaries, Amenities, Access Points, Service Areas | **Script + manual review.** Use `01_update_boundaries.R` to compare the incoming polygon source with the existing boundary master and append genuinely new parks. Review new polygons before accepting the output. Amenity records may be prepared manually or through the appropriate amenity workflow.                                    |
| **A. Park Inventory Change**              | Park identified through Survey123 but absent from the boundary master                           | Identify or obtain the correct polygon → review or create polygon in ArcGIS Pro or ArcGIS Online → add to boundary master → assign new `park_id` → rerun relevant amenity and access point procedures → `04_generate_isochrones.R` → `05_create_exb_data.R` | Potentially all four master datasets                | **Manual + Script.** Polygon identification and creation require case specific GIS review. Once the park is added to the boundary master, existing Survey123 records can be reconsidered against the updated master.                                                                                                                        |
| **A. Park Inventory Change**              | Existing park changes, including boundary, name, ownership, closure status, merger, or division | Edit the approved boundary master → determine whether amenity or access point records are affected → update affected records → regenerate affected service areas if necessary → `05_create_exb_data.R`                                                      | Depends on the type of change                       | **Manual + Script.** These changes generally require case specific review and are best handled in ArcGIS Pro or ArcGIS Online before running the relevant downstream scripts. Preserve existing `park_id` values whenever the park remains the same project entity.                                                                         |
| **B. Amenity Information Change**         | Polygon based external amenity source                                                           | Review source configuration and field mapping → `02a_update_amenities_polygon.R` → review changes → `05_create_exb_data.R`                                                                                                                                  | Amenities                                           | **Automated + review.** Source specific field mappings and spatial matching settings should be checked before each run.                                                                                                                                                                                                                     |
| **B. Amenity Information Change**         | Point based external amenity source                                                             | Review source configuration and field mapping → `02b_update_amenities_point.R` → review matches and changes → `05_create_exb_data.R`                                                                                                                        | Amenities                                           | **Automated + review.** Incoming amenity points are spatially linked to master parks. Review unmatched or ambiguous records before accepting the updated master.                                                                                                                                                                            |
| **B. Amenity Information Change**         | New or updated Survey123 amenity responses                                                      | `02c_update_amenities_survey123.R` → review unmatched and multiple match records → `05_create_exb_data.R`                                                                                                                                                   | Amenities                                           | **Automated + review.** Survey123 responses that match exactly one master park can be incorporated automatically. Records without a unique park match require manual review.                                                                                                                                                                |
| **B. Amenity Information Change**         | Manual correction to an existing amenity record                                                 | Confirm `park_id` → edit the amenity master → QA/QC → `05_create_exb_data.R`                                                                                                                                                                                | Amenities                                           | **Manual + Script.** Small corrections can be made directly in the master amenity table after verifying the correct park and value.                                                                                                                                                                                                         |
| **C. Access Point Change**                | New external entrance, parking, or access point source                                          | Review source configuration → `03a_update_external_access_points.R` → review matched and duplicate points → `04_generate_isochrones.R` → `05_create_exb_data.R`                                                                                             | Access Points, Service Areas                        | **Automated + review.** Incoming access points are linked to parks and checked against existing access points before new records are appended.                                                                                                                                                                                              |
| **C. Access Point Change**                | Park has no verified access point                                                               | `03d_estimate_missing_access_points.R` → review estimated points → `04_generate_isochrones.R` → `05_create_exb_data.R`                                                                                                                                      | Access Points, Service Areas                        | **Automated estimation + QA/QC.** Access points are estimated using OSM parking locations, park boundary and road intersections, and road snapping in hierarchical order. Estimated points should be reviewed before final acceptance.                                                                                                      |
| **C. Access Point Change**                | Survey123 provides a usable park address or access location                                     | Confirm the Survey123 park match → geocode and validate the reported location → append approved access point to the master → `04_generate_isochrones.R` → `05_create_exb_data.R`                                                                            | Access Points, Service Areas                        | **Manual + existing geocoding logic.** `03b_geocode_survey123_access_points.R` contains the geocoding and validation logic originally used to construct access points from Survey123 addresses. For routine maintenance, reviewed records can be incorporated into the existing access point master rather than rebuilding it from scratch. |
| **C. Access Point Change**                | Existing access point is corrected or removed                                                   | Confirm affected `access_point_id` and `park_id` → edit the access point master in ArcGIS Pro or ArcGIS Online → remove or replace the corresponding service area → regenerate affected isochrone if required → `05_create_exb_data.R`                      | Access Points, Service Areas                        | **Manual + Script.** Access point corrections and removals should be reviewed carefully because corresponding service areas must remain synchronized with the access point master.                                                                                                                                                          |
| **D. Downstream Refresh and Publication** | Amenity information changed but access points did not                                           | `05_create_exb_data.R`                                                                                                                                                                                                                                      | Downstream application data                         | **Automated downstream refresh.** Service areas do not need to be regenerated when access point locations have not changed.                                                                                                                                                                                                                 |
| **D. Downstream Refresh and Publication** | Access points were added or changed                                                             | Confirm approved access point master → `04_generate_isochrones.R` → review service areas → `05_create_exb_data.R`                                                                                                                                           | Service Areas, downstream application data          | **Automated + review.** New or changed access points require corresponding service area generation before application data are rebuilt.                                                                                                                                                                                                     |
| **D. Downstream Refresh and Publication** | Updated master datasets are approved for publication                                            | `05_create_exb_data.R` → update hosted feature layers → verify web maps → verify application                                                                                                                                                                | Hosted layers, web maps, application                | **Script + manual publication verification.** After rebuilding application data, update the appropriate ArcGIS Online content and confirm that web maps and the final application reflect the approved master datasets.                                                                                                                     |

## Processing Scripts

| Script                                  | Purpose                                                                                             |
| --------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `01_update_boundaries.R`                | Add new park polygons while preserving existing `park_id` values                                    |
| `02a_update_amenities_polygon.R`        | Update amenities from polygon based sources                                                         |
| `02b_update_amenities_point.R`          | Update amenities from point based sources                                                           |
| `02c_update_amenities_survey123.R`      | Update amenities from regional Survey123 responses                                                  |
| `03a_update_external_access_points.R`   | Add access points from external entrance or parking datasets                                        |
| `03b_geocode_survey123_access_points.R` | Geocode and validate Survey123 park addresses; primarily used for initial access point construction |
| `03c_build_road_network.R`              | Build or refresh statewide OSM roads and parking used for access point estimation                   |
| `03d_estimate_missing_access_points.R`  | Estimate access points for parks without verified access points                                     |
| `04_generate_isochrones.R`              | Generate ten minute driving service areas from access points                                        |
| `05_create_exb_data.R`                  | Rebuild downstream data used by the Experience Builder application                                  |
| `match_survey_to_master.R`              | Shared function for matching Survey123 points to master park polygons                               |

Input paths, output paths, source settings, and other run specific options are defined in the `CONFIG` section of each script.

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

Each maintenance run should create a new dated version rather than overwrite the previous approved master. If multiple versions are created on the same day, use suffixes such as `_1` and `_2`.

Before running a downstream script, confirm that its inputs point to the latest **approved** master datasets.

## Operational Notes

1. **Review before propagation.** Review new polygons, ambiguous Survey123 matches, estimated access points, and other manually resolved records before propagating changes downstream.

2. **Update only affected datasets.** Amenity only changes do not require new service areas. Access point changes do require corresponding service area updates.

3. **Maintain relational consistency.** Amenity and access point records must reference valid `park_id` values. Service areas must reference valid `access_point_id` and `park_id` values.

4. **Survey123 matching.** Records that match exactly one park can be processed automatically. Unmatched or multiple match records require review. Previously unmatched records should be reconsidered after new park polygons are added.

5. **OSM and ORS consistency.** `03c_build_road_network.R`, access point estimation, and service area generation should use consistent North Carolina OSM data whenever practical.

6. **Publication verification.** After an approved update, refresh the required application data, update the relevant ArcGIS Online content, and confirm that the web maps and final application reflect the change.
