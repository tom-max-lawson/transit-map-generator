import pandas as pd
import geopandas as gpd
from shapely import geometry
import mercantile
from tqdm import tqdm
import os
import tempfile
import osmnx as ox


# ============================================================
# CONFIGURATION
# ============================================================
place_name = "Sydney, Australia"
output_fn = "example_building_footprints.geojson"
zoom_level = 9  # control tile resolution for the MS Buildings dataset
# ============================================================


# ------------------------------------------------------------
# Get the area of interest polygon from OpenStreetMap using OSMnx
# ------------------------------------------------------------
print(f"Retrieving area of interest for {place_name} from OSM...")

# You can use geometries_from_place if you want all boundaries,
# but geocode_to_gdf usually suffices and gives you the boundary polygon
aoi_gdf = ox.geocode_to_gdf(place_name)

# Some places have multiple polygons (e.g., metropolitan vs district)
# We unify them into a single geometry
aoi_shape = aoi_gdf.geometry.unary_union

# Get bounding box
minx, miny, maxx, maxy = aoi_shape.bounds
print(f"AOI bounds: ({minx}, {miny}, {maxx}, {maxy})")


# ------------------------------------------------------------
# Determine which Microsoft Buildings tiles intersect this AOI
# ------------------------------------------------------------
quad_keys = {mercantile.quadkey(tile) for tile in mercantile.tiles(minx, miny, maxx, maxy, zooms=zoom_level)}
print(f"The input area spans {len(quad_keys)} tiles.")

# Load dataset index (maps quadkeys to Azure blob URLs)
df = pd.read_csv(
    "https://minedbuildings.z5.web.core.windows.net/global-buildings/dataset-links.csv",
    dtype=str,
)

# ------------------------------------------------------------
# Download and filter building footprints
# ------------------------------------------------------------
combined_gdf = gpd.GeoDataFrame()
idx = 0

with tempfile.TemporaryDirectory() as tmpdir:
    tmp_fns = []

    for quad_key in tqdm(quad_keys, desc="Downloading building tiles"):
        rows = df[df["QuadKey"] == quad_key]
        if len(rows) == 1:
            url = rows.iloc[0]["Url"]
            df2 = pd.read_json(url, lines=True)
            df2["geometry"] = df2["geometry"].apply(geometry.shape)
            gdf = gpd.GeoDataFrame(df2, crs=4326)

            fn = os.path.join(tmpdir, f"{quad_key}.geojson")
            tmp_fns.append(fn)
            gdf.to_file(fn, driver="GeoJSON")

        elif len(rows) > 1:
            # Some tiles are split into multiple parts in dense areas — download all
            for _, row in rows.iterrows():
                url = row["Url"]
                df2 = pd.read_json(url, lines=True)
                df2["geometry"] = df2["geometry"].apply(geometry.shape)
                gdf = gpd.GeoDataFrame(df2, crs=4326)

                fn = os.path.join(tmpdir, f"{quad_key}_{_}.geojson")
                tmp_fns.append(fn)
                gdf.to_file(fn, driver="GeoJSON")

        else:
            print(f"Warning: QuadKey {quad_key} not found in dataset, skipping.")

    # Merge and filter
    for fn in tmp_fns:
        gdf = gpd.read_file(fn)
        # Keep only buildings inside the AOI polygon
        gdf = gdf[gdf.geometry.within(aoi_shape)]
        gdf["id"] = range(idx, idx + len(gdf))
        idx += len(gdf)
        combined_gdf = pd.concat([combined_gdf, gdf], ignore_index=True)

# ------------------------------------------------------------
# Save combined output
# ------------------------------------------------------------
combined_gdf = combined_gdf.to_crs("EPSG:4326")
combined_gdf.to_file(output_fn, driver="GeoJSON")

print(f"\n✅ Saved {len(combined_gdf)} building footprints to {output_fn}")
