import os
import json
import osmnx as ox
from shapely.geometry import LineString

# ---------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------
INPUT_GRAPHML = "sydney.graphml"          # your saved OSMnx graph
OUTPUT_JSON   = "sydney_graph_geometry.json"
OUTPUT_DIR    = "exports"
os.makedirs(OUTPUT_DIR, exist_ok=True)

# ---------------------------------------------------------------
# LOAD GRAPHML
# ---------------------------------------------------------------
print(f"📂 Loading {INPUT_GRAPHML} ...")
G = ox.load_graphml(INPUT_GRAPHML)
print(f"✅ Loaded graph: {len(G.nodes)} nodes, {len(G.edges)} edges")

# ---------------------------------------------------------------
# BUILD DATA STRUCTURE
# ---------------------------------------------------------------
data = {"nodes": {}, "edges": {}}

# --- Nodes ---
for nid, nd in G.nodes(data=True):
    data["nodes"][str(nid)] = {
        "x": float(nd["x"]),
        "y": float(nd["y"])
    }

# --- Edges ---
for u, v, ed in G.edges(data=True):
    # Geometry
    if "geometry" in ed and isinstance(ed["geometry"], LineString):
        coords = [[float(x), float(y)] for x, y in ed["geometry"].coords]
    else:
        coords = [
            [float(G.nodes[u]["x"]), float(G.nodes[u]["y"])],
            [float(G.nodes[v]["x"]), float(G.nodes[v]["y"])]
        ]
    
    edge = {
        "target": str(v),
        "length": float(ed.get("length", 0.0)),
        "geometry": coords
    }

    data["edges"].setdefault(str(u), []).append(edge)

# ---------------------------------------------------------------
# WRITE JSON
# ---------------------------------------------------------------
output_path = os.path.join(OUTPUT_DIR, OUTPUT_JSON)
with open(output_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=1)

print(f"💾 Export complete → {output_path}")
print(f"Nodes: {len(data['nodes'])}, Edges: {sum(len(v) for v in data['edges'].values())}")
