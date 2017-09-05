#include "Expanding.h"

Expanding::Expanding(GraphIO* graph_io) {
	_graph_io = graph_io;
	_sampler = new Sampling(_graph_io);
	_random_node_sampler = new RandomNodeSampling(_graph_io);
}

void Expanding::collect_expanding_parameters(char* argv[]) {
	// Factor
	SCALING_FACTOR = atof(argv[4]);
	printf("\nFactor: %f", SCALING_FACTOR);

	// Fraction
	SAMPLING_FRACTION = atof(argv[5]);
	printf("\nFraction per sample: %f", SAMPLING_FRACTION); // TODO: Residu
	
	// Bridge
	char* bridge = argv[7];
	if (strcmp(bridge, "high_degree") == 0) {
		_bridge_selection = new HighDegree();
		printf("\nBridge: %s", "high degree");
	}
	else if (strcmp(bridge, "random") == 0) {
		_bridge_selection = new RandomBridge();
		printf("\nBridge: %s", "random");
	}
	else {
		printf("\nGiven bridge type is undefined.");
		exit(1);
	}

	//  Interconnection
	sscanf(argv[8], "%d", &AMOUNT_INTERCONNECTIONS);
	printf("\nAmount of interconnection: %d", AMOUNT_INTERCONNECTIONS);

	// Force undirected (TODO: Should be optional)
	char* force_undirected = argv[9];
	if (strcmp(force_undirected, "undirected") == 0) {
		FORCE_UNDIRECTED_BRIDGES = true;
		printf("\nUndirected bridges added.");
	}

	// Topology
	char* topology = argv[6];

	printf("\nTopology: ");

	if (strcmp(topology, "star") == 0) {
		_topology = new Star(AMOUNT_INTERCONNECTIONS, _bridge_selection, FORCE_UNDIRECTED_BRIDGES);
		printf("%s", "star");
	}
	else if (strcmp(topology, "chain") == 0) {
		_topology = new Chain(AMOUNT_INTERCONNECTIONS, _bridge_selection, FORCE_UNDIRECTED_BRIDGES);
		printf("%s", "chain");
	}
	else if (strcmp(topology, "circle") == 0) {
		_topology = new Ring(AMOUNT_INTERCONNECTIONS, _bridge_selection, FORCE_UNDIRECTED_BRIDGES);
		printf("%s", "circle");
	}
	else if (strcmp(topology, "mesh") == 0) {
		_topology = new FullyConnected(AMOUNT_INTERCONNECTIONS, _bridge_selection, FORCE_UNDIRECTED_BRIDGES);
		printf("%s", "mesh");
	}
	else {
		printf("\nGiven topology type is undefined.");
		exit(1);
	}

}


void Expanding::expand_graph_random_node_sampling(char* input_path, char* output_path) {
	std::vector<int> source_vertices;
	std::vector<int> destination_vertices;
	COO_List* coo_list = _graph_io->load_graph_from_edge_list_file_to_coo(source_vertices, destination_vertices, input_path);
	CSR_List* csr_list = _graph_io->convert_coo_to_csr_format(coo_list->source, coo_list->destination);

	int amount_of_sampled_graphs = SCALING_FACTOR / SAMPLING_FRACTION;

	float residu = fmod(SCALING_FACTOR, SAMPLING_FRACTION);
	if (residu > 0) {
		amount_of_sampled_graphs += 1;
	}

	printf("Amount of sampled graph versions: %d", amount_of_sampled_graphs);

	Sampled_Vertices** sampled_vertices_per_graph = (Sampled_Vertices**)malloc(sizeof(Sampled_Vertices)*amount_of_sampled_graphs);

	int** d_size_collected_edges = (int**)malloc(sizeof(int*)*amount_of_sampled_graphs);
	Edge** d_edge_data_expanding = (Edge**)malloc(sizeof(Edge*)*amount_of_sampled_graphs);

	Sampled_Graph_Version* sampled_graph_version_list = new Sampled_Graph_Version[amount_of_sampled_graphs];
	char current_label_1 = 'a';
	char current_label_2 = 'a';

	_random_node_sampler->SAMPLING_FRACTION = SAMPLING_FRACTION;

	for (int i = 0; i < amount_of_sampled_graphs; i++) {
		if (i == amount_of_sampled_graphs - 1) {
			if (residu>0) {
				printf("Change sampe fraction to residu");
				_random_node_sampler->SAMPLING_FRACTION = residu;
			}
		}

		std::unordered_set<int> random_nodes = _random_node_sampler->node_selection_step(source_vertices, destination_vertices);

		// (Partial) Induction step
		std::vector<Edge> edges = _random_node_sampler->induction_step(source_vertices, destination_vertices, random_nodes);
		
		Sampled_Graph_Version* sampled_graph_version = new Sampled_Graph_Version();
		(*sampled_graph_version).edges = edges;

		// Label
		sampled_graph_version->label_1 = current_label_1;
		sampled_graph_version->label_2 = current_label_2;

		increment_labels(&current_label_1, &current_label_2);

		// Copy data to the sampled version list
		sampled_graph_version_list[i] = (*sampled_graph_version);

		// Cleanup
		delete(sampled_graph_version);
	}

	// Topology, bridges and interconnections
	std::vector<Bridge_Edge> bridge_edges;
	_topology->link(sampled_graph_version_list, amount_of_sampled_graphs, bridge_edges);
	printf("\nConnected by adding a total of %d bridge edges.", bridge_edges.size());

	// Write expanded graph to output file
	_graph_io->write_expanded_output_to_file(sampled_graph_version_list, amount_of_sampled_graphs, bridge_edges, output_path);

	// Cleanup
	delete[] sampled_graph_version_list;
}

// TODO: refactor (sampling should be a basis for expanding)
void Expanding::expand_graph(char* input_path, char* output_path) {
	std::vector<int> source_vertices;
	std::vector<int> destination_vertices;
	COO_List* coo_list = _graph_io->load_graph_from_edge_list_file_to_coo(source_vertices, destination_vertices, input_path);
	CSR_List* csr_list = _graph_io->convert_coo_to_csr_format(coo_list->source, coo_list->destination);

	int amount_of_sampled_graphs = SCALING_FACTOR / SAMPLING_FRACTION;

	float residu = fmod(SCALING_FACTOR,SAMPLING_FRACTION);
	if (residu > 0) {
		amount_of_sampled_graphs += 1;
	}

	printf("Amount of sampled graph versions: %d", amount_of_sampled_graphs);
	
	Sampled_Vertices** sampled_vertices_per_graph = (Sampled_Vertices**)malloc(sizeof(Sampled_Vertices)*amount_of_sampled_graphs);

	int** d_size_collected_edges = (int**)malloc(sizeof(int*)*amount_of_sampled_graphs);
	Edge** d_edge_data_expanding = (Edge**)malloc(sizeof(Edge*)*amount_of_sampled_graphs);

	Sampled_Graph_Version* sampled_graph_version_list = new Sampled_Graph_Version[amount_of_sampled_graphs];
	char current_label_1 = 'a';
	char current_label_2 = 'a';

	int* d_offsets;
	int* d_indices;
	gpuErrchk(cudaMalloc((void**)&d_offsets, sizeof(int) * (_graph_io->SIZE_VERTICES + 1)));
	gpuErrchk(cudaMalloc((void**)&d_indices, sizeof(int) * _graph_io->SIZE_EDGES));

	gpuErrchk(cudaMemcpyToSymbol(&D_SIZE_EDGES, &(_graph_io->SIZE_EDGES), sizeof(int), 0, cudaMemcpyHostToDevice));
	gpuErrchk(cudaMemcpyToSymbol(&D_SIZE_VERTICES, &(_graph_io->SIZE_VERTICES), sizeof(int), 0, cudaMemcpyHostToDevice));

	gpuErrchk(cudaMemcpy(d_indices, csr_list->indices, _graph_io->SIZE_EDGES * sizeof(int), cudaMemcpyHostToDevice));
	gpuErrchk(cudaMemcpy(d_offsets, csr_list->offsets, sizeof(int) * (_graph_io->SIZE_VERTICES + 1), cudaMemcpyHostToDevice));

	_sampler->SAMPLING_FRACTION = SAMPLING_FRACTION;

	for (int i = 0; i < amount_of_sampled_graphs; i++) {
		if (i == amount_of_sampled_graphs-1) {
			if (residu>0) {
				printf("Change sampe fraction to residu");
				_sampler->SAMPLING_FRACTION = residu;
			}
		}
		sampled_vertices_per_graph[i] = _sampler->perform_edge_based_node_sampling_step(coo_list->source, coo_list->destination);
		printf("\nCollected %d vertices.", sampled_vertices_per_graph[i]->sampled_vertices_size);

		int* d_sampled_vertices;
		gpuErrchk(cudaMalloc((void**)&d_sampled_vertices, sizeof(int) * _graph_io->SIZE_VERTICES));
		gpuErrchk(cudaMemcpy(d_sampled_vertices, sampled_vertices_per_graph[i]->vertices, sizeof(int) * (_graph_io->SIZE_VERTICES), cudaMemcpyHostToDevice));
		
		int* h_size_edges = 0;
		gpuErrchk(cudaMalloc((void**)&d_size_collected_edges[i], sizeof(int)));
		gpuErrchk(cudaMemcpy(d_size_collected_edges[i], &h_size_edges, sizeof(int), cudaMemcpyHostToDevice));

		gpuErrchk(cudaMalloc((void**)&d_edge_data_expanding[i], sizeof(Edge) * _graph_io->SIZE_EDGES));

		cudaDeviceSynchronize(); // This can be deleted - double check

		printf("\nRunning kernel (induction step) with block size %d and thread size %d:", get_block_size(), get_thread_size());
		perform_induction_step_expanding(get_block_size(), get_thread_size(), d_sampled_vertices, d_offsets, d_indices, d_edge_data_expanding[i], d_size_collected_edges[i]);
		//perform_induction_step_expanding <<<get_block_size(), get_thread_size()>>>(d_sampled_vertices, d_offsets, d_indices, d_edge_data_expanding[i], d_size_collected_edges[i]);

		// Edge size
		int h_size_edges_result;
		gpuErrchk(cudaMemcpy(&h_size_edges_result, d_size_collected_edges[i], sizeof(int), cudaMemcpyDeviceToHost));

		// Edges
		printf("\nh_size_edges: %d", h_size_edges_result);
		Sampled_Graph_Version* sampled_graph_version = new Sampled_Graph_Version();
		(*sampled_graph_version).edges.resize(h_size_edges_result);

		gpuErrchk(cudaMemcpy(&sampled_graph_version->edges[0], d_edge_data_expanding[i], sizeof(Edge)*(h_size_edges_result), cudaMemcpyDeviceToHost));

		// Label
		sampled_graph_version->label_1 = current_label_1;
		sampled_graph_version->label_2 = current_label_2;

		increment_labels(&current_label_1, &current_label_2);

		// Copy data to the sampled version list
		sampled_graph_version_list[i] = (*sampled_graph_version);

		// Cleanup
		delete(sampled_graph_version);

		cudaFree(d_sampled_vertices);
		cudaFree(d_edge_data_expanding[i]);
		cudaFree(d_size_collected_edges);
		free(sampled_vertices_per_graph[i]->vertices);
		free(sampled_vertices_per_graph[i]);
	}

	cudaFree(d_offsets);
	cudaFree(d_indices);
	free(sampled_vertices_per_graph);
	free(coo_list);
	free(csr_list->indices);
	free(csr_list->offsets);
	free(csr_list);

	// Topology, bridges and interconnections
	std::vector<Bridge_Edge> bridge_edges;
	_topology->link(sampled_graph_version_list, amount_of_sampled_graphs, bridge_edges);
	printf("\nConnected by adding a total of %d bridge edges.", bridge_edges.size());

	// Write expanded graph to output file
	_graph_io->write_expanded_output_to_file(sampled_graph_version_list, amount_of_sampled_graphs, bridge_edges, output_path);

	// Cleanup
	delete[] sampled_graph_version_list;
}

void Expanding::increment_labels(char* label_1, char* label_2) {
	if (*label_1 == 'z' && *label_2 == 'z') { // TODO: Check in the beginning of the expanding algo
		printf("Expand scaling factor limit reached (26*26).");
		exit(1);
	}

	if (*label_1 == 'z') {
		*label_1 = 'a';
		(*label_2)++;
	}
	else {
		(*label_1)++;
	}
}

int Expanding::get_thread_size() {
	return ((_graph_io->SIZE_VERTICES + 1) > MAX_THREADS) ? MAX_THREADS : _graph_io->SIZE_VERTICES;
}
int Expanding::get_block_size() {
	return ((_graph_io->SIZE_VERTICES + 1) > MAX_THREADS) ? ((_graph_io->SIZE_VERTICES / MAX_THREADS) + 1) : 1;
}

// Only for debugging purposes
void Expanding::set_topology(Topology* topology) {
	_topology = topology;
}

Expanding::~Expanding() {
	delete(_sampler);
	delete(_topology);
}