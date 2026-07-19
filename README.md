# Park Access Points, Drive Time Isochrones, and Survey123 Template

This repository provides reusable Strive for Access materials, including R workflows for generating park access points and 10 minute drive time isochrones, along with a Survey123 XLSForm template for local park and recreation data collection.

## Overview

The repository includes two main components:

1. R scripts for generating a filtered road network, park access points, and 10 minute driving isochrones.
2. A Survey123 XLSForm template that local agencies can download, customize, and publish within their own ArcGIS organization.

The R workflow produces three spatial outputs:

1. A road network filtered for vehicle accessibility, used as the basis for access point generation.
2. A point layer of plausible access locations for each park polygon.
3. A polygon layer of 10 minute driving isochrones around those access points, generated via OpenRouteService.

The access point logic uses a four step fallback so that every park polygon receives at least one access point, even when no formal entrance or parking lot exists in the source data.

## Scripts

### 00_ors_roads_filter.R

Generates a county level road network suitable for park access point estimation, adapted from the [OpenRouteService driving-car tag filtering profile](https://giscience.github.io/openrouteservice/technical-details/tag-filtering#driving-car). The script is parameterized by county and state, so it can be reused for any U.S. county.

Key features:

- Pulls the official TIGER/Line county boundary via tigris and uses it for both the Overpass query bounding box and a final clip step, avoiding the boundary spillover that occurs when querying by place name through Nominatim.
- Replicates the ORS driving-car rules for road type, ford crossings, track grade, impassable status, and width, with two project specific modifications: motorway is removed (park entrances rarely connect directly to controlled-access highways, though motorway_link is retained for interchange ramps), and restricted access values are treated as a hard reject except for access=forestry, which is preserved so that state forest and game land access roads are not falsely excluded.
- Outputs a cleaned road network to ./Data/{county}/{county}_roads_ors.geojson, where {county} is the lowercased county name.

### 01_generate_access_points_wake.R

Generates one or more access points per park polygon using the following fallback order:

1. Known entrances from an existing public access point dataset, assigned to the nearest park polygon.
2. OSM parking locations identified with amenity=parking, using centroids that fall inside the remaining parks and clustering points within 50 m to avoid duplicates.
3. Boundary intersections between park boundaries and the road network, also clustered within 50 m.
4. Snapped points projected from the park polygon onto the nearest road, used as a last resort.

Each output point carries a PointID, the parent SiteID, and a source field indicating which step produced it. An interactive tmap preview is included for visual inspection.

### 02_generate_iso10min_wake.R

Generates 10 minute driving isochrones for each access point using the OpenRouteService API.

Key features:

- Loops through access points with a 1.5 second delay to respect API rate limits.
- Saves a checkpoint every 50 points so long runs can be resumed if interrupted.
- Tracks failed requests separately for later inspection.

## Survey123 Template

This repository also includes Strive4Access_Survey123.xlsx, an XLSForm template that can be used to create a local park and recreation data collection survey in ArcGIS Survey123.

The template is intended to help local agencies adapt the Strive for Access survey structure for their own parks, facilities, and recreation assets. Users can download the file, modify the survey choices, and publish the form within their own ArcGIS organization.

### How to use the template

1. Download Strive4Access_Survey123.xlsx from this repository.
2. Open ArcGIS Survey123 Connect.
3. Click New Survey, choose the File option, and browse to the downloaded .xlsx file.
4. Once the survey is loaded, click the XLSForm icon to edit the template.
5. Update the choices tab with local park names, facilities, amenities, or other locally relevant attributes.
6. Click Publish to deploy the survey within your own ArcGIS organization.

## Inputs

The R scripts assume the following files under ./Data/:

- RecLandsAll.geojson: park polygons covering the study region.
- Parks_in_Wake_County.geojson: known public access points.

County boundaries are pulled from tigris. The road network is produced by script 00. Parking data is queried live from OpenStreetMap via osmdata.

## Outputs

The R workflow produces the following outputs (paths shown for Wake County; the road network script generalizes to any county):

- Data/wake/wake_roads_ors.geojson: filtered road network for the county.
- Data/Wake/wake_polygons.geojson: park polygons clipped to the county, with assigned SiteID.
- Data/Wake/wake_access_points.geojson: combined access points from all four steps.
- Data/Wake/wake_iso10min_checkpoint.geojson: 10 minute drive time isochrones, which also serve as the resumable checkpoint.

## Dependencies

R packages:

- sf
- dplyr
- tidyverse
- purrr
- osmdata
- tigris
- tmap
- uuid
- lwgeom
- openrouteservice

An OpenRouteService API key is required for script 2. Set it in your R session before running:

```r
library(openrouteservice)
ors_api_key("YOUR_KEY")





# SFA Master Dataset Workflow

This repository contains the R scripts used to build and maintain the versioned master datasets for the Strive for Access project.

The workflow includes four linked datasets:

1. Park boundary dataset
2. Park amenity dataset
3. Park access point dataset
4. Drive time service area dataset

Each processing script reads the latest available master dataset and writes a new dated version. Stable identifiers are preserved across versions so that records can be linked between datasets.

## Data Processing Workflow

```mermaid
---
config:
  theme: base
  themeVariables:
    fontFamily: ''
    fontSize: 13px
    lineColor: '#5F6368'
  flowchart:
    htmlLabels: true
    curve: basis
    nodeSpacing: 24
    rankSpacing: 42
  layout: dagre
---
flowchart TB

 subgraph BOUNDARY["1. Park Boundary Dataset"]
    direction LR

    B1["<b>Data sources</b><br><br>External boundary datasets<br><br>Survey123 geometry correction requests"]

    B2["<b>Update master boundaries</b><br><br>Standardize fields and geometry<br><br>Compare with master and append only new parks<br><br>Preserve park_id UUIDs and assign IDs to new parks only<br><br><span style='color:#1A73E8'>01_update_park_boundaries.R</span>"]

    B3["<b>Manual review in GIS</b><br><br>Resolve overlaps and duplicates<br><br>Apply Survey123 geometry corrections"]

    B4[("<b>Master Park Boundary Dataset</b><br><br>Validated park polygons<br><br>Primary key: park_id")]
 end

 subgraph AMENITY["2. Park Amenity Dataset"]
    direction LR

    A1["<b>Data sources</b><br><br>External polygon based datasets<br><br>External point based datasets<br><br>Survey123 amenity responses"]

    A2["<b>Update from external datasets</b><br><br>Standardize amenity fields<br><br>Spatially match records to parks<br><br>Update confirmed amenity values<br><br><span style='color:#1A73E8'>02a_update_amenities_polygon.R</span><br><span style='color:#1A73E8'>02b_update_amenities_point.R</span>"]

    A3["<b>Update from Survey123</b><br><br>Match responses to parks<br><br>Summarize duplicate responses per park<br><br>Update reviewed amenity values<br><br><span style='color:#1A73E8'>02c_update_amenities_survey123.R</span><br><i style='color:#1A73E8'>uses match_survey_to_master.R</i>"]

    A4[("<b>Master Park Amenity Dataset</b><br><br>One amenity record per park<br><br>Primary key: park_id")]
 end

 subgraph ACCESS["3. Park Access Point Dataset"]
    direction LR

    P1["<b>Data sources</b><br><br>External access point datasets<br><br>Survey123 park addresses<br><br>OSM parking and road data"]

    P2["<b>Update from external and Survey123</b><br><br>Standardize external points<br><br>Geocode and validate Survey123 addresses<br><br>Deduplicate and append with new access_point_id UUIDs<br><br><span style='color:#1A73E8'>03a_update_external_access_points.R</span><br><span style='color:#1A73E8'>03b_geocode_survey123_access_points.R</span><br><i style='color:#1A73E8'>uses match_survey_to_master.R</i>"]

    P3["<b>Complete coverage</b><br><br>Build ORS filtered road network per county<br><br>Estimate points for parks without coverage:<br>OSM parking, boundary road intersection,<br>nearest road snapping<br><br><span style='color:#1A73E8'>03c_build_road_network.R</span><br><span style='color:#1A73E8'>03d_estimate_missing_access_points.R</span>"]

    P5[("<b>Master Park Access Point Dataset</b><br><br>Validated park access points<br><br>Primary key: access_point_id<br>Foreign key: park_id")]
 end

 subgraph SERVICE["4. Drive Time Service Area Dataset"]
    direction LR

    T1["<b>Generate service areas</b><br><br>One 10 minute isochrone per access point<br><br>Union isochrones by park_id<br><br>Checkpointing enables incremental updates<br><br><span style='color:#1A73E8'>04_generate_service_areas.R</span>"]

    T3[("<b>Master Drive Time Service Area Dataset</b><br><br>One 10 minute service area per park<br><br>Primary key: park_id")]
 end

 M[("<b style='font-size:16px'>Versioned SFA Master Datasets</b><br><br><b>boundaries/</b> boundaries_YYYYMMDD.gpkg<br><b>amenities/</b> amenities_YYYYMMDD.csv<br><b>access_points/</b> access_points_YYYYMMDD.gpkg<br><b>service_areas/</b> service_areas_YYYYMMDD.gpkg<br><br><i>Each script reads the latest version as input<br>and writes a new dated version</i>")]

 B1 ==> B2
 B2 ==> B3
 B3 ==> B4

 A1 ==> A2
 A1 ==> A3
 A2 ==> A4
 A3 ==> A4

 P1 ==> P2
 P2 ==> P3
 P3 ==> P5

 P5 ==> T1
 T1 ==> T3

 B4 -. park geometry and park_id .-> A1
 B4 -. park geometry and park_id .-> P1

 B4 -.-> M
 A4 -.-> M
 P5 -.-> M
 T3 -.-> M

 class B1,A1,P1 standard
 class B2,A2,A3,P2,P3,T1 script
 class B3 manual
 class B4,A4,P5,T3 output
 class M master

 classDef standard fill:#F7F7F7,stroke:#5F6368,stroke-width:1.5px,color:#202124
 classDef script fill:#F7F7F7,stroke:#3C4043,stroke-width:2px,color:#202124
 classDef manual fill:#FFFFFF,stroke:#5F6368,stroke-width:1.5px,stroke-dasharray:5 3,color:#202124
 classDef output fill:#F7F7F7,stroke:#5F6368,stroke-width:2px,color:#202124
 classDef master fill:#F7F7F7,stroke:#3C4043,stroke-width:2.5px,color:#202124
```

## Dataset Relationships

The park boundary dataset provides the authoritative park geometry and `park_id`.

The amenity dataset contains one amenity record for each park and uses `park_id` as its primary key.

The access point dataset may contain multiple access points for each park. Each record has a unique `access_point_id` and is linked to the corresponding park through `park_id`.

The service area dataset contains one combined 10 minute drive time service area for each park and uses `park_id` as its primary key.

## Versioned Outputs

```text
data/
  master/
    boundaries/
      boundaries_YYYYMMDD.gpkg

    amenities/
      amenities_YYYYMMDD.csv

    access_points/
      access_points_YYYYMMDD.gpkg

    service_areas/
      service_areas_YYYYMMDD.gpkg
```

## Processing Scripts

```text
R/
  01_update_park_boundaries.R

  02a_update_amenities_polygon.R
  02b_update_amenities_point.R
  02c_update_amenities_survey123.R

  03a_update_external_access_points.R
  03b_geocode_survey123_access_points.R
  03c_build_road_network.R
  03d_estimate_missing_access_points.R

  04_generate_service_areas.R

  functions/
    match_survey_to_master.R
```

## Identifier Structure

| Dataset                  | Primary key       | Foreign key |
| :----------------------- | :---------------- | :---------- |
| Park boundaries          | `park_id`         |             |
| Park amenities           | `park_id`         |             |
| Park access points       | `access_point_id` | `park_id`   |
| Drive time service areas | `park_id`         |             |

Existing identifiers are preserved during updates. New identifiers are assigned only when a new park or access point is appended to a master dataset.

