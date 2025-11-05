import osmnx as ox
import json
import shapely.geometry as geom
import math
import geopandas as gpd

# ========== CONFIG ==========
PLACE_NAME = "Sydney, Australia"
OUTPUT_PATH_JSON = "buildings.json"
OUTPUT_PATH_GEOJSON = "osm-buildings.geojson"
DEFAULT_HEIGHT = 5.0        # meters, if no height info is available
LEVEL_HEIGHT = 5.0          # per floor (used when building:levels is provided)
# ============================


def get_height(tags):
    """Estimate building height from OSM tags, ensuring a finite numeric result."""
    h = tags.get("height")
    if h:
        try:
            # Remove 'm' or whitespace, parse float
            val = float(str(h).replace("m", "").strip())
            if math.isfinite(val):
                return val
        except ValueError:
            pass

    levels = tags.get("building:levels")
    if levels:
        try:
            val = float(levels) * LEVEL_HEIGHT
            if math.isfinite(val):
                return val
        except ValueError:
            pass

    # Fallback to default
    return DEFAULT_HEIGHT


def main():
    print(f"📦 Downloading buildings for: {PLACE_NAME}")
    gdf = ox.features_from_place(PLACE_NAME, tags={"building": True})
    print(f"Fetched {len(gdf)} building features")

    # Project to UTM for planar meters
    gdf = ox.projection.project_gdf(gdf)

    buildings = []
    geojson_records = []

    for _, row in gdf.iterrows():
        geom_obj = row.geometry
        if geom_obj is None or geom_obj.is_empty:
            continue

        tags = row.to_dict()
        height = get_height(tags)
        if not math.isfinite(height):
            height = DEFAULT_HEIGHT

        # Handle polygons and multipolygons
        polygons = []
        if isinstance(geom_obj, geom.MultiPolygon):
            polygons = list(geom_obj.geoms)
        elif isinstance(geom_obj, geom.Polygon):
            polygons = [geom_obj]
        else:
            continue

        for poly in polygons:
            if not poly.is_valid or poly.exterior is None:
                continue
            coords = list(poly.exterior.coords)
            if any(math.isnan(x) or math.isnan(y) for x, y in coords):
                continue

            footprint = [[float(x), float(y)] for x, y in coords]
            buildings.append({
                "footprint": footprint,
                "height": height
            })

            # For GeoJSON export
            geojson_records.append({
                "geometry": poly,
                "height": height
            })

    print(f"🧱 Valid buildings exported: {len(buildings)}")

    # ---------- Save JSON ----------
    with open(OUTPUT_PATH_JSON, "w", encoding="utf-8") as f:
        json.dump({"buildings": buildings}, f, allow_nan=False)
    print(f"✅ Saved {len(buildings)} buildings to {OUTPUT_PATH_JSON}")

    # ---------- Save GeoJSON ----------
    geo_gdf = gpd.GeoDataFrame(geojson_records, geometry="geometry", crs=gdf.crs)
    # Reproject to WGS84 for compatibility with MS dataset
    geo_gdf = geo_gdf.to_crs(4326)
    geo_gdf.to_file(OUTPUT_PATH_GEOJSON, driver="GeoJSON")
    print(f"🌍 GeoJSON exported to {OUTPUT_PATH_GEOJSON} with {len(geo_gdf)} features")


if __name__ == "__main__":
    main()
