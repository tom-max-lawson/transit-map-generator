#!/usr/bin/env python3
import json
import numpy as np
import pandas as pd
import osmnx as ox
import geopandas as gpd
from sklearn.cluster import DBSCAN

# ==========================================
#   CONFIG
# ==========================================
CITY_NAME = "Sydney, Australia"
GRID_SIZE_M = 250
MERGE_RADIUS_M = 50       # distance threshold for merging POIs (m)
OUTPUT_FILE = "poi_grid.json"

# Category mapping (single source of truth)
CATEGORIES = {
    "work": {
        "tags": [
            ("office", "*"),
            ("industrial", "*")
        ],
        "priority": 10
    },
    "shopping": {
        "tags": [
            ("shop", "*")
        ],
        "priority": 20
    },
    "education": {
        "tags": [
            ("amenity", "school"),
            ("amenity", "university"),
            ("amenity", "college")
        ],
        "priority": 30
    },
    "healthcare": {
        "tags": [
            ("amenity", "hospital"),
            ("amenity", "clinic"),
            ("amenity", "pharmacy")
        ],
        "priority": 40
    },
    "leisure": {
        "tags": [
            ("amenity", "cinema"),
            ("amenity", "theatre"),
            ("amenity", "arts_centre"),
            ("amenity", "library"),
            ("amenity", "bar"),
            ("amenity", "pub"),
            ("amenity", "restaurant"),
            ("amenity", "cafe"),
            ("leisure", "*")
        ],
        "priority": 50
    },
    "transit": {
        "tags": [
            ("railway", "station"),
            ("aeroway", "aerodrome")
        ],
        "priority": 5
    },
}

# ==========================================
#   HELPERS
# ==========================================
def classify_poi(tags: dict) -> str | None:
    """Pick highest priority matching category."""
    best = None
    best_p = -999
    for cat, rule in CATEGORIES.items():
        for key, allowed in rule["tags"]:
            val = tags.get(key)
            if val is None:
                continue
            if allowed == "*" or val == allowed:
                if rule["priority"] > best_p:
                    best = cat
                    best_p = rule["priority"]
    return best


def fetch_category(boundary, key, value):
    try:
        if value == "*":
            return ox.features_from_polygon(boundary, {key: True})
        return ox.features_from_polygon(boundary, {key: value})
    except Exception:
        return gpd.GeoDataFrame()


def clean_and_merge_pois(gdf: gpd.GeoDataFrame, merge_radius_m: float) -> gpd.GeoDataFrame:
    """Merge nearby POIs within merge_radius_m *per category*; add multiplicity field."""
    if gdf.empty:
        gdf["multiplicity"] = []
        return gdf

    merged_parts = []

    for cat, subset in gdf.groupby("category"):
        if subset.empty:
            continue

        coords = np.vstack([subset.geometry.x, subset.geometry.y]).T
        db = DBSCAN(eps=merge_radius_m, min_samples=1).fit(coords)
        subset = subset.copy()
        subset["cluster_id"] = db.labels_

        grouped = (
            subset.groupby("cluster_id", as_index=False)
            .agg({
                "geometry": lambda g: g.unary_union.centroid,
                "category": "first"
            })
        )
        grouped["multiplicity"] = subset.groupby("cluster_id").size().values
        merged_parts.append(grouped)

        # 🧾 One-liner per-category summary
        before = len(subset)
        after = len(grouped)
        avg_mult = grouped["multiplicity"].mean()
        print(f"🧹 Merged {cat}: {before} → {after} (avg mult {avg_mult:.2f})")

    merged = pd.concat(merged_parts, ignore_index=True)
    merged = gpd.GeoDataFrame(merged, geometry="geometry", crs=gdf.crs)

    print(f"🧹 Total merged POIs: {len(gdf)} → {len(merged)} (overall avg mult {merged['multiplicity'].mean():.2f})")
    return merged



# ==========================================
#   1) City boundary in WGS84
# ==========================================
print(f"📍 Fetching boundary: {CITY_NAME}")
boundary = ox.geocode_to_gdf(CITY_NAME)
geom = boundary.geometry.iloc[0]

# ==========================================
#   2) Project boundary to auto-UTM
# ==========================================
geom_utm, utm_crs = ox.projection.project_geometry(geom)
print("✅ Auto-selected CRS:", utm_crs)

minx, miny, maxx, maxy = geom_utm.bounds
num_x = int(np.ceil((maxx - minx) / GRID_SIZE_M))
num_y = int(np.ceil((maxy - miny) / GRID_SIZE_M))

export = {
    "grid": {
        "cell_size_m": GRID_SIZE_M,
        "crs": utm_crs.to_string(),
        "min_x": float(minx),
        "min_y": float(miny),
        "num_x": num_x,
        "num_y": num_y
    },
    "cells": {}
}

# ==========================================
#   3) Fetch POIs
# ==========================================
print("🔎 Fetching OSM POIs...")
all_pois = gpd.GeoDataFrame(columns=["geometry"], crs="EPSG:4326")
boundary_simple = boundary.to_crs(epsg=4326).simplify(0.0005, preserve_topology=True)

for cat, rule in CATEGORIES.items():
    for key, val in rule["tags"]:
        gdf = fetch_category(boundary_simple.geometry.iloc[0], key, val)
        if not gdf.empty:
            if gdf.crs is None:
                gdf.set_crs(epsg=4326, inplace=True)
            all_pois = pd.concat([all_pois, gdf], ignore_index=True)

all_pois.drop_duplicates(subset=["geometry"], inplace=True)
print("✅ Raw POIs:", len(all_pois))

# ==========================================
#   4) Project to UTM + centroid
# ==========================================
if all_pois.empty:
    raise RuntimeError("No POIs found.")

pois = all_pois.copy()
pois = pois.to_crs(utm_crs)
pois["geometry"] = pois.centroid

# ==========================================
#   5) Extract tags & classify
# ==========================================
def row_tags(row):
    return {k: v for k, v in row.items() if isinstance(v, str)}

pois["tags"] = pois.apply(row_tags, axis=1)
pois["category"] = pois["tags"].apply(classify_poi)
pois = pois[pois["category"].notnull()]
print("Classified POIs:", len(pois))

# ==========================================
#   5.5) CLEAN & MERGE NEARBY POIs
# ==========================================
pois = clean_and_merge_pois(pois, merge_radius_m=MERGE_RADIUS_M)
print("✅ Classified POIs after clustering:", len(pois))

# ==========================================
#   6) Assign POIs to grid cells
# ==========================================
print("📦 Assigning POIs to grid cells...")

for idx, row in pois.iterrows():
    px = row.geometry.x
    py = row.geometry.y
    mult = int(row.get("multiplicity", 1))

    ix = int((px - minx) // GRID_SIZE_M)
    iy = int((py - miny) // GRID_SIZE_M)

    cell_id = ix * num_y + iy
    cell_key = str(cell_id)

    if cell_key not in export["cells"]:
        export["cells"][cell_key] = {
            "ix": ix,
            "iy": iy,
            "pois": []
        }

    export["cells"][cell_key]["pois"].append({
        "category": row["category"],
        "multiplicity": mult,
        "pos_utm": [float(px), float(py)]
    })

print("✅ Cells with POIs:", len(export["cells"]))

# ==========================================
#   7) Write JSON
# ==========================================
with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
    json.dump(export, f, indent=2)

print("\n🎯 Export complete!")
print("→", OUTPUT_FILE)
print("Grid:", num_x, "x", num_y)
