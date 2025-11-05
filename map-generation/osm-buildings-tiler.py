import os
import math
import json
import osmnx as ox
import shapely.geometry as geom
from shapely.ops import unary_union

# ========== CONFIG ==========
PLACE_NAME = "Sydney, Australia"
OUTPUT_DIR = "sydney_buildings"
TILE_SIZE = 1000.0            # in meters (1 km × 1 km)
DEFAULT_HEIGHT = 5.0  # Could be different for different cities. E.g. in Australia it is 1-storey, maybe in a place like Paris it is 5 storeys.
LEVEL_HEIGHT = 5.0  # Height of one storey
# ============================


def get_height(tags):
    """Extract or estimate building height in meters."""
    h = tags.get("height")
    if h:
        try:
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

    return DEFAULT_HEIGHT


def get_tile_index(x, y, minx, miny):
    """Convert UTM coords → tile indices relative to global min bounds."""
    ix = int(math.floor((x - minx) / TILE_SIZE))
    iy = int(math.floor((y - miny) / TILE_SIZE))
    return ix, iy


def main():
    print(f"📦 Downloading buildings for {PLACE_NAME}")
    gdf = ox.features_from_place(PLACE_NAME, tags={"building": True})
    print(f"Fetched {len(gdf)} building features")

    gdf = ox.projection.project_gdf(gdf)
    print("Projected to UTM coordinate system")

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Compute bounding box
    minx, miny, maxx, maxy = gdf.total_bounds
    print(f"Map extent: X=({minx:.1f}, {maxx:.1f})  Y=({miny:.1f}, {maxy:.1f})")

    # Group buildings into tiles
    tiles = {}

    for _, row in gdf.iterrows():
        geom_obj = row.geometry
        if geom_obj is None or geom_obj.is_empty:
            continue

        height = get_height(row.to_dict())

        # Handle MultiPolygons
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

            # Determine which tile it belongs to (by centroid)
            cx, cy = poly.centroid.x, poly.centroid.y
            ix, iy = get_tile_index(cx, cy, minx, miny)
            tile_key = (ix, iy)

            if tile_key not in tiles:
                tiles[tile_key] = []

            tiles[tile_key].append({
                "footprint": [[float(x), float(y)] for x, y in coords],
                "height": float(height)
            })

    print(f"🧩 Created {len(tiles)} tiles")

    # Save one file per tile
    for (ix, iy), buildings in tiles.items():
        if not buildings:
            continue

        tile_x = minx + ix * TILE_SIZE
        tile_y = miny + iy * TILE_SIZE
        filename = os.path.join(OUTPUT_DIR, f"tile_{ix}_{iy}.json")

        with open(filename, "w", encoding="utf-8") as f:
            json.dump({
                "tile_origin": [tile_x, tile_y],
                "tile_size": TILE_SIZE,
                "buildings": buildings
            }, f, allow_nan=False)

    print(f"✅ Export complete: {len(tiles)} JSON tiles saved in '{OUTPUT_DIR}'")


if __name__ == "__main__":
    main()
