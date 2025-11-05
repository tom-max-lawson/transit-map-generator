#!/usr/bin/env python3
"""
Pack a single large GeoJSON of building footprints into a tiled, compressed format
for streaming in Godot.

Produces:
  - buildings.pack  (binary blob of zlib-compressed tile JSONs)
  - buildings.index.json  (offset/length table)
"""

import json
import zlib
from pathlib import Path
import geopandas as gpd
from shapely.geometry import shape
from tqdm import tqdm

# ------------------------------------------------------------------------------
# 🔧 SETTINGS — EDIT THESE
# ------------------------------------------------------------------------------
INPUT_GEOJSON = "merged_buildings_utm.geojson"
OUTPUT_FOLDER = "packed_buildings"
TILE_SIZE_M = 1000.0          # Tile size in coordinate units (e.g. meters)
HEIGHT_FIELD = "height"       # Property name in GeoJSON for building height
DEFAULT_HEIGHT = 5.0         # Fallback height if missing
COMPRESSION = "zlib"          # "zlib" or "zstd"
# ------------------------------------------------------------------------------


def pack_buildings():
    out_dir = Path(OUTPUT_FOLDER)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"📂 Loading GeoJSON: {INPUT_GEOJSON}")
    gdf = gpd.read_file(INPUT_GEOJSON)
    print(f"✅ Loaded {len(gdf)} features")

    minx, miny, maxx, maxy = gdf.total_bounds
    print(f"🌐 Bounds: X[{minx:.1f}, {maxx:.1f}]  Y[{miny:.1f}, {maxy:.1f}]")

    tiles = {}
    tile_size = TILE_SIZE_M

    # --- Iterate through all features with a progress bar ---
    print("🧱 Grouping buildings into tiles...")
    for _, row in tqdm(gdf.iterrows(), total=len(gdf), smoothing=0.1, ncols=80):
        geom = shape(row.geometry)
        if geom.is_empty:
            continue
        centroid = geom.centroid
        ix = int((centroid.x - minx) // tile_size)
        iy = int((centroid.y - miny) // tile_size)
        key = (ix, iy)

        height = float(row.get(HEIGHT_FIELD, DEFAULT_HEIGHT))
        coords = list(geom.exterior.coords)
        building = {
            "footprint": [[float(x), float(y)] for (x, y) in coords],
            "height": height,
        }
        tiles.setdefault(key, []).append(building)

    print(f"🧩 Created {len(tiles)} tiles")

    pack_path = out_dir / "buildings.pack"
    index_path = out_dir / "buildings.index.json"
    offset = 0
    index = {}

    print("📦 Writing compressed tiles...")
    with open(pack_path, "wb") as pack_f:
        for (ix, iy), buildings in tqdm(sorted(tiles.items()), ncols=80):
            json_bytes = json.dumps(buildings, separators=(",", ":")).encode("utf-8")
            if COMPRESSION == "zlib":
                comp_bytes = zlib.compress(json_bytes)
            else:
                import zstandard
                comp_bytes = zstandard.ZstdCompressor(level=3).compress(json_bytes)
            length = len(comp_bytes)
            pack_f.write(comp_bytes)
            index[f"{ix},{iy}"] = {"offset": offset, "length": length}
            offset += length

    with open(index_path, "w", encoding="utf-8") as f:
        json.dump(index, f, indent=2)

    total_mb = offset / 1e6
    print(f"✅ Wrote {pack_path}  ({total_mb:.2f} MB)")
    print(f"✅ Wrote {index_path}  ({len(index)} tiles)")
    print("🏁 Done.")


if __name__ == "__main__":
    pack_buildings()