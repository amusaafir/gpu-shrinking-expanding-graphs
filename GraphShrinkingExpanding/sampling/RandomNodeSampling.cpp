// TODO: Strategy pattern between sampling algorithms

#include "RandomNodeSampling.h"

RandomNodeSampling::RandomNodeSampling(GraphIO* graph_io) {
	_graph_io = graph_io;
}

void RandomNodeSampling::collect_sampling_parameters(char* argv[]) {
	float fraction = atof(argv[4]);
	SAMPLING_FRACTION = fraction;
	printf("\nSample fraction: %f", fraction);
}

void RandomNodeSampling::sample_graph(char* input_path, char* output_path) {
	std::vector<int> source_vertices;
	std::vector<int> destination_vertices;

	// Convert edge list to COO
	COO_List* coo_list = _graph_io->load_graph_from_edge_list_file_to_coo(source_vertices, destination_vertices, input_path);

	// Node selection step
	std::unordered_set<int> random_nodes = node_selection_step(source_vertices, destination_vertices);
	
	// (Partial) Induction step
	std::vector<Edge> edges = induction_step(source_vertices, destination_vertices, random_nodes);

	printf("edges size: %d", edges.size());
	_graph_io->write_output_to_file(edges, output_path);
}

// TODO: rename to selection step when refactoring the project
std::unordered_set<int> RandomNodeSampling::node_selection_step(std::vector<int>& source_vertices, std::vector<int>& destination_vertices) {
	printf("\nPerforming node selection step.\n");

	// Select random nodes from the original vertices set
	int required_amount_sampled_vertices = calculate_node_sampled_size();
	std::random_device seeder;
	std::mt19937 engine(seeder());
	std::unordered_set<int> random_node_vertices;
	std::vector<int> vertices_original_graph(_graph_io->get_vertices_original_graph().begin(), _graph_io->get_vertices_original_graph().end());
	
	while (random_node_vertices.size()<required_amount_sampled_vertices) {
		std::uniform_int_distribution<int> range_vertices(0, (_graph_io->SIZE_VERTICES - 1)); // Don't select the last element in the offset
		int random_vertex_index = range_vertices(engine);
		random_node_vertices.insert(vertices_original_graph[random_vertex_index]);
	}

	return random_node_vertices;
}

// Partial induction step
std::vector<Edge> RandomNodeSampling::induction_step(std::vector<int>& source_vertices, std::vector<int>& destination_vertices, std::unordered_set<int>& random_nodes) {
	std::vector<Edge> edges;

	for (int edge_index = 0; edge_index < source_vertices.size(); edge_index++) {
		if (random_nodes.count(source_vertices[edge_index]) && random_nodes.count(destination_vertices[edge_index])) {
				Edge edge;
				edge.source = source_vertices[edge_index];
				edge.destination = destination_vertices[edge_index];
				edges.push_back(edge);
		}
	}
	
	return edges;
}

int RandomNodeSampling::calculate_node_sampled_size() {
	return int(_graph_io->SIZE_VERTICES * SAMPLING_FRACTION);
}