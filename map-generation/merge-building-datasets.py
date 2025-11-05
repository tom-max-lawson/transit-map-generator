import geopandas as gpd
import pandas as pd
from tqdm import tqdm
import math

osm_gdf = gpd.read_file("osm-buildings.geojson")
ms_gdf  = gpd.read_file("ms-buildings.geojson")

print(f"🚀 Starting merge: {len(osm_gdf)} OSM + {len(ms_gdf)} MS buildings")

# ============================================================
# 🧭 Estimate a local projected CRS (UTM) automatically
# ============================================================
utm_crs = osm_gdf.estimate_utm_crs()
print(f"📐 Using projected CRS: {utm_crs.to_string()}")

osm_gdf = osm_gdf.to_crs(utm_crs)
ms_gdf  = ms_gdf.to_crs(utm_crs)

# ============================================================
# ⚙️ Chunked merge with progress
# ============================================================
CHUNK_SIZE = 100_000
num_chunks = math.ceil(len(ms_gdf) / CHUNK_SIZE)
out_parts = []

for i, start in enumerate(range(0, len(ms_gdf), CHUNK_SIZE)):
    end = min(start + CHUNK_SIZE, len(ms_gdf))
    ms_chunk = ms_gdf.iloc[start:end]
    print(f"🧩 Processing chunk {i+1}/{num_chunks} ({len(ms_chunk)} features)...")

    joined = gpd.sjoin(ms_chunk, osm_gdf[["geometry"]],
                       how="left", predicate="intersects")

    # Keep only MS buildings that don't intersect OSM
    ms_unique = joined[joined["index_right"].isna()].drop(columns="index_right")
    out_parts.append(ms_unique)

# Combine results
ms_unique_all = pd.concat(out_parts, ignore_index=True)
merged = pd.concat([osm_gdf, ms_unique_all], ignore_index=True)

print(f"✅ Finished merge: {len(merged)} total buildings "
      f"({len(ms_unique_all)} new from Microsoft)")

# ============================================================
# 💾 Save result (still in projected UTM CRS)
# ============================================================
merged.to_file("merged_buildings_utm.geojson", driver="GeoJSON")
print("💾 Saved merged dataset to merged_buildings_utm.geojson")
