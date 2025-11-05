import osmnx as ox
import shapely
import json
import pandas as pd

# --- Define city and categories ---
place_name = "Sydney, Australia"
categories = {
    "water": {"natural": "water"},
    "artificial_greenery": [
        {"leisure": "park"},
        {"landuse": "recreation_ground"},
        {"landuse": "grass"}
    ],
    "natural_greenery": [
        {"leisure": "nature_reserve"},
        {"natural": "wood"},
        {"landuse": "forest"},
        {"landuse": "meadow"}
    ],
    "beach": [
        {"natural": "beach"},
        {"natural": "sand"}
    ]
}

# --- Helper to fetch features ---
def get_features(place, tag_dicts):
    dfs = []
    for tags in tag_dicts:
        df = ox.features_from_place(place, tags)
        dfs.append(df)
    if dfs:
        return pd.concat(dfs, ignore_index=True)
    else:
        return None

# --- Determine UTM projection for Sydney ---
print("Determining UTM zone for Sydney...")
city_gdf = ox.geocode_to_gdf(place_name)
utm_crs = ox.projection.project_gdf(city_gdf).crs
print(f"Using CRS: {utm_crs}")

# --- Collect features for each category ---
data = {}
for cat, tags in categories.items():
    print(f"Fetching {cat}...")
    gdf = get_features(place_name, tags if isinstance(tags, list) else [tags])
    if gdf is not None and not gdf.empty:
        gdf = gdf.to_crs(utm_crs)  # Project to local UTM zone
        gdf["geometry"] = gdf["geometry"].simplify(5)
        polys = []
        for geom in gdf.geometry:
            if geom.is_empty:
                continue
            if geom.geom_type == "Polygon":
                polys.append(list(geom.exterior.coords))
            elif geom.geom_type == "MultiPolygon":
                for poly in geom.geoms:
                    polys.append(list(poly.exterior.coords))
        data[cat] = polys
    else:
        data[cat] = []
        print(f"No data found for {cat}.")

# --- Save to JSON ---
output = {
    "place": place_name,
    "crs": str(utm_crs),
    "categories": data
}
with open("sydney_ground_utm.json", "w", encoding="utf-8") as f:
    json.dump(output, f, indent=2)

print("✅ Saved sydney_ground_utm.json with categories:", list(data.keys()))
