# Park Access Points and Drive-Time Isochrones

R scripts for generating park access points and 10-minute drive-time isochrones, developed for the Strive for Access project. The code is shared here so the logic can be reused with other data.

## Overview

The workflow produces two outputs:

1. A point layer of plausible access locations for each park polygon.
2. A polygon layer of 10-minute driving isochrones around those access points, generated via OpenRouteService.

The access point logic uses a four-step fallback so that every park polygon receives at least one access point, even when no formal entrance or parking lot exists in the source data.

## Scripts

### `01_generate_access_points_wake.R`

Generates one or more access points per park polygon using the following fallback order:

1. **Known entrances** from an existing public access point dataset, assigned to the nearest park polygon.
2. **OSM parking** (`amenity=parking`) whose centroids fall inside the remaining parks, clustered within 50 m to avoid duplicates.
3. **Boundary intersections** between park boundaries and the road network, also clustered within 50 m.
4. **Snapped points** projected from the park polygon onto the nearest road, used as a last resort.

Each output point carries a `PointID`, the parent `SiteID`, and a `source` field indicating which step produced it. An interactive `tmap` preview is included for visual inspection.

### `02_generate_iso10min_wake.R`

Generates 10-minute driving isochrones for each access point using the OpenRouteService API.

Key features:

* Loops through access points with a 1.5-second delay to respect API rate limits.
* Saves a checkpoint every 50 points so long runs can be resumed if interrupted.
* Tracks failed requests separately for later inspection.

## Inputs

The scripts assume the following files under `./Data/`:

* `Audrey/RecLandsAll.geojson`: park polygons covering the study region.
* `Wake/wake_roads_ors.geojson`: road network used for boundary intersection and snapping.
* `Parks_in_Wake_County.geojson`: known public access points.

County boundaries are pulled from `tigris` (Wake County, NC). Parking data is queried live from OpenStreetMap via `osmdata`.

## Outputs

* `Data/Wake/wake_polygons.geojson`: park polygons clipped to the county, with assigned `SiteID`.
* `Data/Wake/wake_access_points.geojson`: combined access points from all four steps.
* `Data/Wake/wake_iso10min_checkpoint.geojson`: 10-minute drive-time isochrones (also serves as the resumable checkpoint).

## Dependencies

R packages: `sf`, `dplyr`, `purrr`, `osmdata`, `tigris`, `tmap`, `uuid`, `lwgeom`, `openrouteservice`.

An OpenRouteService API key is required for script 2. Set it in your R session before running:

```r
library(openrouteservice)
ors_api_key("YOUR_KEY")
```

## Adapting to other regions

To apply this workflow elsewhere:

1. Replace the park polygon file and known access point file with your own inputs.
2. Update the `tigris::counties()` filter to your target county and state.
3. Provide a road network covering the new study area.
4. Adjust the projected CRS (currently EPSG:26917, UTM Zone 17N) to one appropriate for your region.
5. Run the two scripts in order.

The 50 m clustering threshold and the 600-second (10-minute) isochrone range are exposed as plain numeric arguments and can be tuned to match local conditions.
