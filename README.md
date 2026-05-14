# Park Access Points, Drive Time Isochrones, and Survey123 Template

This repository provides reusable Strive for Access materials, including R workflows for generating park access points and 10 minute drive time isochrones, along with a Survey123 XLSForm template for local park and recreation data collection.

## Overview

The repository includes two main components:

1. R scripts for generating park access points and 10 minute driving isochrones.

2. A Survey123 XLSForm template that local agencies can download, customize, and publish within their own ArcGIS organization.

The R workflow produces two spatial outputs:

1. A point layer of plausible access locations for each park polygon.

2. A polygon layer of 10 minute driving isochrones around those access points, generated via OpenRouteService.

The access point logic uses a four step fallback so that every park polygon receives at least one access point, even when no formal entrance or parking lot exists in the source data.

## Scripts

### `01_generate_access_points_wake.R`

Generates one or more access points per park polygon using the following fallback order:

1. Known entrances from an existing public access point dataset, assigned to the nearest park polygon.

2. OSM parking locations identified with `amenity=parking`, using centroids that fall inside the remaining parks and clustering points within 50 m to avoid duplicates.

3. Boundary intersections between park boundaries and the road network, also clustered within 50 m.

4. Snapped points projected from the park polygon onto the nearest road, used as a last resort.

Each output point carries a `PointID`, the parent `SiteID`, and a `source` field indicating which step produced it. An interactive `tmap` preview is included for visual inspection.

### `02_generate_iso10min_wake.R`

Generates 10 minute driving isochrones for each access point using the OpenRouteService API.

Key features:

1. Loops through access points with a 1.5 second delay to respect API rate limits.

2. Saves a checkpoint every 50 points so long runs can be resumed if interrupted.

3. Tracks failed requests separately for later inspection.

## Survey123 Template

This repository also includes `Strive4Access_Survey123.xlsx`, an XLSForm template that can be used to create a local park and recreation data collection survey in ArcGIS Survey123.

The template is intended to help local agencies adapt the Strive for Access survey structure for their own parks, facilities, and recreation assets. Users can download the file, modify the survey choices, and publish the form within their own ArcGIS organization.

### How to use the template

1. Download `Strive4Access_Survey123.xlsx` from this repository.

2. Open ArcGIS Survey123 Connect.

3. Click **New Survey**, choose the **File** option, and browse to the downloaded `.xlsx` file.

4. Once the survey is loaded, click the XLSForm icon to edit the template.

5. Update the **choices** tab with local park names, facilities, amenities, or other locally relevant attributes.

6. Click **Publish** to deploy the survey within your own ArcGIS organization.

## Inputs

The R scripts assume the following files under `./Data/`:

1. `RecLandsAll.geojson`: park polygons covering the study region.

2. `Wake/wake_roads_ors.geojson`: road network used for boundary intersection and snapping.

3. `Parks_in_Wake_County.geojson`: known public access points.

County boundaries are pulled from `tigris` for Wake County, North Carolina. Parking data is queried live from OpenStreetMap via `osmdata`.

## Outputs

The R workflow produces the following outputs:

1. `Data/Wake/wake_polygons.geojson`: park polygons clipped to the county, with assigned `SiteID`.

2. `Data/Wake/wake_access_points.geojson`: combined access points from all four steps.

3. `Data/Wake/wake_iso10min_checkpoint.geojson`: 10 minute drive time isochrones, which also serve as the resumable checkpoint.

## Dependencies

R packages:

1. `sf`

2. `dplyr`

3. `purrr`

4. `osmdata`

5. `tigris`

6. `tmap`

7. `uuid`

8. `lwgeom`

9. `openrouteservice`

An OpenRouteService API key is required for script 2. Set it in your R session before running:

```r
library(openrouteservice)
ors_api_key("YOUR_KEY")
