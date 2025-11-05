# A prototype for downloading a road network from OSM

import osmnx as ox
import networkx as nx

# Download all drivable roads in Sydney
G = ox.graph_from_place("Sydney, Australia", network_type='drive')

# Automatically select an appropriate UTM zone and project it to 2D linear space
G = ox.project_graph(G)

# Optionally save to file for offline reuse
ox.save_graphml(G, "sydney.graphml")