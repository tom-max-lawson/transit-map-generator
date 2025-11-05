import osmnx as ox
import networkx as nx

# Load pre-existing graph
G = ox.load_graphml("sydney.graphml")

# Visualise the graph
print(type(G))
print("Nodes:", len(G.nodes))
print("Edges:", len(G.edges))

ox.plot_graph(G, bgcolor='white', node_size=0, edge_color='black', edge_linewidth=0.4)

# # Plot a route
# # Example coordinates (Opera House → Sydney Airport)
# orig_point = (-33.8568, 151.2153)
# dest_point = (-33.9399, 151.1753)

# # Find nearest nodes
# orig = ox.distance.nearest_nodes(G, orig_point[1], orig_point[0])
# dest = ox.distance.nearest_nodes(G, dest_point[1], dest_point[0])

# # Compute shortest path by distance
# route = ox.shortest_path(G, orig, dest, weight='length')

# # Plot the route on the map
# ox.plot_graph_route(G, route, route_color='red', route_linewidth=3)