/*
NOTE: Run in VS using x64 platform.

TODO:

SHRINKING:
- Look into edge based vs CSR based device.
- Load graph should be a separate method

EXPANDING:
- Option for undirected (edge interconnection)
- Expanding fraction (e.g. 3.5) - what about the 0.5
- Investigate stream expanding
- Make it somewhat nice so that the user can change these properties easily.
- Decrease size of char in Bridge_Edge

ANALYSIS
- Check snap tool

OVERALL
- Refactor code (multiple files, remove code duplicates)
- Get rid of using mixed C/C++
*/

#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <nvgraph.h>
#include "device_functions.h"
#include <curand.h>
#include <curand_kernel.h>
#include <math.h>
#include <time.h>
#include <stdlib.h>
#include <iostream>
#include <fstream>
#include <random>
#include <unordered_set>
#include <unordered_map>
#include <map>
#include <algorithm>

#define MAX_THREADS 1024
#define ENABLE_DEBUG_LOG false

int SIZE_VERTICES;
int SIZE_EDGES;
bool IS_INPUT_FILE_COO = false;

typedef enum Bridge_Node_Selection {HIGH_DEGREE_NODES, RANDOM_NODES} Bridge_Node_Selection;
typedef enum Topology {STAR, CHAIN, CIRCLE, MESH};
bool FORCE_UNDIRECTED_BRIDGES = false;
float SAMPLING_FRACTION;
float EXPANDING_FACTOR;
int AMOUNT_INTERCONNECTIONS;

Bridge_Node_Selection SELECTED_BRIDGE_NODE_SELECTION;
Topology SELECTED_TOPOLOGY;

typedef struct Sampled_Vertices sampled_vertices;
typedef struct COO_List coo_list;
typedef struct CSR_List csr_list;
typedef struct Edge edge;
typedef struct Sampled_Graph_Version;
typedef struct Bridge_Edge;
void load_graph_from_edge_list_file(int*, int*, char*);
COO_List* load_graph_from_edge_list_file_to_coo(std::vector<int>&, std::vector<int>&, char*);
int add_vertex_as_coordinate(std::vector<int>&, std::unordered_map<int, int>&, int, int);
int get_thread_size();
int calculate_node_sampled_size(float);
int get_block_size();
Sampled_Vertices* perform_edge_based_node_sampling_step(int*, int*, float);
void print_debug_log(char*);
void print_debug_log(char*, int);
void print_coo(int*, int*);
void print_csr(int*, int*);
void sample_graph(char*, char*, float);
CSR_List* convert_coo_to_csr_format(int*, int*);
void expand_graph(char*, char*, float);
void link_using_star_topology(Sampled_Graph_Version*, int, std::vector<Bridge_Edge>&);
void link_using_line_topology(Sampled_Graph_Version*, int, std::vector<Bridge_Edge>&);
void link_using_circle_topology(Sampled_Graph_Version*, int, std::vector<Bridge_Edge>&);
void link_using_mesh_topology(Sampled_Graph_Version*, int, std::vector<Bridge_Edge>&);
void add_edge_interconnection_between_graphs(Sampled_Graph_Version*, Sampled_Graph_Version*, std::vector<Bridge_Edge>&);
int select_random_bridge_vertex(Sampled_Graph_Version*);
int select_high_degree_node_bridge_vertex(Sampled_Graph_Version*);
int get_random_high_degree_node(Sampled_Graph_Version*);
void collect_sampling_parameters(char* argv[]);
void collect_expanding_parameters(char* argv[]);
void write_expanded_output_to_file(Sampled_Graph_Version*, int, std::vector<Bridge_Edge>&, char*);
void write_output_to_file(std::vector<Edge>&, char* output_path);
void save_input_file_as_coo(std::vector<int>&, std::vector<int>&, char*);
int get_node_bridge_vertex(Sampled_Graph_Version*);
void check(nvgraphStatus_t);

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort = true)
{
	if (code != cudaSuccess)
	{
		fprintf(stderr, "GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
		if (abort) exit(code);
	}
}

typedef struct COO_List {
	int* source;
	int* destination;
} COO_List;

typedef struct CSR_List {
	int* offsets;
	int* indices;
} CSR_List;

typedef struct Sampled_Vertices {
	int* vertices;
	int sampled_vertices_size;
} Sampled_Vertices;

typedef struct Edge {
	int source, destination;
} Edge;

typedef struct Sampled_Graph_Version {
	std::vector<Edge> edges;
	std::vector<int> high_degree_nodes;
	char label;
} Sampled_Graph_Version;

typedef struct Bridge_Edge {
	char source[20];
	char destination[20];
} Bridge_Edge;

__device__ int d_edge_count = 0;
__constant__ int D_SIZE_EDGES;
__constant__ int D_SIZE_VERTICES;

__device__ int push_edge(Edge &edge, Edge* d_edge_data) {
	int edge_index = atomicAdd(&d_edge_count, 1);
	if (edge_index < D_SIZE_EDGES) {
		d_edge_data[edge_index] = edge;
		return edge_index;
	}
	else {
		printf("Maximum edge size threshold reached: %d", D_SIZE_EDGES);
		return -1;
	}
}

__global__
void perform_induction_step(int* sampled_vertices, int* offsets, int* indices, Edge* d_edge_data) {
	int neighbor_index_start_offset = blockIdx.x * blockDim.x + threadIdx.x;
	
	if (neighbor_index_start_offset < D_SIZE_VERTICES) {
		int neighbor_index_end_offset = neighbor_index_start_offset + 1;

		for (int n = offsets[neighbor_index_start_offset]; n < offsets[neighbor_index_end_offset]; n++) {
			if (sampled_vertices[neighbor_index_start_offset] && sampled_vertices[indices[n]]) {
				//printf("\nAdd edge: (%d,%d).", neighbor_index_start_offset, indices[n]);
				Edge edge;
				edge.source = neighbor_index_start_offset;
				edge.destination = indices[n];
				push_edge(edge, d_edge_data);
			}
		}
	}
}

clock_t t1;
clock_t t2;
clock_t total_t;

void perform_sequential_induction_step(int* sampled_vertices, int* offsets, int* indices, std::vector<Edge>& edges) {
	t1 = clock();
	for (int p = 0; p < SIZE_VERTICES; p++) {
		//printf("\n\nVertex %d", p);
		
		int startOffset = offsets[p];
		int endOffset = offsets[p + 1];
		//printf("\nHas neighbor:");
		for (int i = startOffset; i < endOffset ; i++) {
			//printf("%d, ", indices[i]);
			if (sampled_vertices[p] && sampled_vertices[indices[i]]) {
				//printf("\nAdd edge: (%d, %d)", p, indices[i]);
				Edge edge;
				edge.source = p;
				edge.destination = indices[i];
				edges.push_back(edge);
			}
		}
	}
	t2 = clock() - t1;
	printf("It took me %d clicks (%f seconds).\n", t2, ((float)t2) / CLOCKS_PER_SEC);
}

__device__ int push_edge_expanding(Edge &edge, Edge* edge_data_expanding, int* d_edge_count_expanding) {
	int edge_index = atomicAdd(d_edge_count_expanding, 1);
	if (edge_index < D_SIZE_EDGES) {
		edge_data_expanding[edge_index] = edge;
		return edge_index;
	}
	else {
		printf("Maximum edge size threshold reached.");
		return -1;
	}
}

__global__
void perform_induction_step_expanding(int* sampled_vertices, int* offsets, int* indices, Edge* edge_data_expanding, int* d_edge_count_expanding) {
	int neighbor_index_start_offset = blockIdx.x * blockDim.x + threadIdx.x;
	
	if (neighbor_index_start_offset < D_SIZE_VERTICES) {
		int neighbor_index_end_offset = neighbor_index_start_offset + 1;

		for (int n = offsets[neighbor_index_start_offset]; n < offsets[neighbor_index_end_offset]; n++) {
			if (sampled_vertices[neighbor_index_start_offset] && sampled_vertices[indices[n]]) {
				//printf("\nAdd edge: (%d,%d).", neighbor_index_start_offset, indices[n]);
				Edge edge;
				edge.source = neighbor_index_start_offset;
				edge.destination = indices[n];
				push_edge_expanding(edge, edge_data_expanding, d_edge_count_expanding);
			}
		}
	}
}

int main(int argc, char* argv[]) {
	if (argc >= 4) {
		char* input_path = argv[1];
		char* output_path = argv[2];

		if (strcmp(argv[3], "sample") == 0) {
			collect_sampling_parameters(argv);
			sample_graph(input_path, output_path, SAMPLING_FRACTION);
		}
		else {
			collect_expanding_parameters(argv);
			expand_graph(input_path, output_path, EXPANDING_FACTOR);
		}
	} else {
		printf("Incorrect amount of input/output arguments given.");

		// ONLY FOR LOCAL TESTING
		//char* input_path = "C:\\Users\\AJ\\Documents\\example_graph.txt";
		//char* input_path = "C:\\Users\\AJ\\Desktop\\nvgraphtest\\nvGraphExample-master\\nvGraphExample\\web-Stanford.txt";
		char* input_path = "C:\\Users\\AJ\\Desktop\\nvgraphtest\\nvGraphExample-master\\nvGraphExample\\web-Stanford_large.txt";
		//char* input_path = "C:\\Users\\AJ\\Desktop\\edge_list_example.txt";
		//char* input_path = "C:\\Users\\AJ\\Desktop\\roadnet.txt";
		//char* input_path = "C:\\Users\\AJ\\Desktop\\new_datasets\\facebook_graph.txt";
		//char* input_path = "C:\\Users\\AJ\\Desktop\\output_test\\social\\soc-pokec-relationships.txt";
		//char* input_path = "C:\\Users\\AJ\\Desktop\\new_datasets\\roadNet-PA.txt";
		//char* input_path = "C:\\Users\\AJ\\Desktop\\new_datasets\\soc-pokec-relationships.txt";
		//char* input_path = "C:\\Users\\AJ\\Desktop\\new_datasets\\com-orkut.ungraph.txt";
		//char* input_path = "C:\\Users\\AJ\\Desktop\\new_datasets\\soc-LiveJournal1.txt";
		//char* input_path = "C:\\Users\\AJ\\Desktop\\new_datasets\\coo\\pokec_coo.txt";
		char* output_path = "C:\\Users\\AJ\\Desktop\\new_datasets\\output\\performance_testing.txt";

		/*sample_graph(input_path, output_path, 0.5);
		*/
		EXPANDING_FACTOR = 3;
		SAMPLING_FRACTION = 0.5;
		SELECTED_TOPOLOGY = STAR;
		SELECTED_BRIDGE_NODE_SELECTION = RANDOM_NODES;
		AMOUNT_INTERCONNECTIONS = 10;
		FORCE_UNDIRECTED_BRIDGES = true;
		expand_graph(input_path, output_path, EXPANDING_FACTOR);
	}

	return 0;
}

void collect_sampling_parameters(char* argv[]) {
	float fraction = atof(argv[4]);
	SAMPLING_FRACTION = fraction;
	printf("\nSample fraction: %f", fraction);
}

void collect_expanding_parameters(char* argv[]) {
	// Factor
	EXPANDING_FACTOR = atof(argv[4]);
	printf("\nFactor: %f", EXPANDING_FACTOR);

	// Fraction
	SAMPLING_FRACTION = atof(argv[5]);
	printf("\nFraction per sample: %f", SAMPLING_FRACTION); // TODO: Residu

	// Topology
	char* topology = argv[6];
	if (strcmp(topology, "star") == 0) {
		SELECTED_TOPOLOGY = STAR;
		printf("\nTopology: %s", "star");
	} else if (strcmp(topology, "chain") == 0) {
		SELECTED_TOPOLOGY = CHAIN;
		printf("\nTopology: %s", "chain");
	} else if (strcmp(topology, "circle") == 0) {
		SELECTED_TOPOLOGY = CIRCLE;
		printf("\nTopology: %s", "circle");
	} else if (strcmp(topology, "mesh") == 0) {
		SELECTED_TOPOLOGY = MESH;
		printf("\nTopology: %s", "mesh");
	} else {
		printf("\nGiven topology type is undefined.");
		exit(1);
	}

	// Bridge
	char* bridge = argv[7];
	if (strcmp(bridge, "high_degree") == 0) {
		SELECTED_BRIDGE_NODE_SELECTION = HIGH_DEGREE_NODES;
		printf("\nBridge: %s", "high degree");
	} else if (strcmp(bridge, "random") == 0) {
		SELECTED_BRIDGE_NODE_SELECTION = RANDOM_NODES;
		printf("\nBridge: %s", "random");
	} else {
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
}

void sample_graph(char* input_path, char* output_path, float fraction) {
	std::vector<int> source_vertices;
	std::vector<int> destination_vertices;

	// Convert edge list to COO
	COO_List* coo_list = load_graph_from_edge_list_file_to_coo(source_vertices, destination_vertices, input_path);
	
	// Convert the COO graph into a CSR format (for the in-memory GPU representation) 
	CSR_List* csr_list = convert_coo_to_csr_format(coo_list->source, coo_list->destination);

	// Edge based Node Sampling Step
	Sampled_Vertices* sampled_vertices = perform_edge_based_node_sampling_step(coo_list->source, coo_list->destination, fraction);
	printf("\nCollected %d vertices.", sampled_vertices->sampled_vertices_size);

	// Induction step (TODO: re-use device memory from CSR conversion)
	int* d_offsets;
	int* d_indices;
	gpuErrchk(cudaMalloc((void**)&d_offsets, sizeof(int)*(SIZE_VERTICES + 1)));
	gpuErrchk(cudaMalloc((void**)&d_indices, sizeof(int)*SIZE_EDGES));
	gpuErrchk(cudaMemcpy(d_indices, csr_list->indices, SIZE_EDGES * sizeof(int), cudaMemcpyHostToDevice));
	gpuErrchk(cudaMemcpy(d_offsets, csr_list->offsets, sizeof(int)*(SIZE_VERTICES + 1), cudaMemcpyHostToDevice));

	int* d_sampled_vertices;
	gpuErrchk(cudaMalloc((void**)&d_sampled_vertices, sizeof(int)*SIZE_VERTICES));
	gpuErrchk(cudaMemcpy(d_sampled_vertices, sampled_vertices->vertices, sizeof(int)*(SIZE_VERTICES), cudaMemcpyHostToDevice));

	gpuErrchk(cudaMemcpyToSymbol(D_SIZE_EDGES, &SIZE_EDGES, sizeof(int), 0, cudaMemcpyHostToDevice));
	gpuErrchk(cudaMemcpyToSymbol(D_SIZE_VERTICES, &SIZE_VERTICES, sizeof(int), 0, cudaMemcpyHostToDevice));

	Edge* d_edge_data;
	gpuErrchk(cudaMalloc((void**)&d_edge_data, sizeof(Edge)*SIZE_EDGES));

	printf("\nRunning kernel (induction step) with block size %d and thread size %d:", get_block_size(), get_thread_size());
	perform_induction_step <<<get_block_size(), get_thread_size() >> >(d_sampled_vertices, d_offsets, d_indices, d_edge_data);

	int h_edge_count;
	gpuErrchk(cudaMemcpyFromSymbol(&h_edge_count, d_edge_count, sizeof(int)));
	if (h_edge_count >= SIZE_EDGES + 1) {
		printf("overflow error\n"); return;
	}

	printf("\nAmount of edges collected: %d", h_edge_count);
	std::vector<Edge> results(h_edge_count);
	gpuErrchk(cudaMemcpy(&(results[0]), d_edge_data, h_edge_count * sizeof(Edge), cudaMemcpyDeviceToHost));
	
	write_output_to_file(results, output_path);

	cudaFree(d_offsets);
	cudaFree(d_indices);
	cudaFree(d_sampled_vertices);
	
	// Cleanup
	free(sampled_vertices->vertices);
	free(sampled_vertices);

	free(coo_list);

	free(csr_list->indices);
	free(csr_list->offsets);
	free(csr_list);
}

/*
Fast conversion to CSR - Using nvGraph for conversion
Modified from: github.com/bmass02/nvGraphExample
*/
CSR_List* convert_coo_to_csr_format(int* source_vertices, int* target_vertices) {
	printf("\nConverting COO to CSR format.");
	CSR_List* csr_list = (CSR_List*)malloc(sizeof(CSR_List));
	csr_list->offsets = (int*)malloc((SIZE_VERTICES + 1) * sizeof(int));
	csr_list->indices = (int*)malloc(SIZE_EDGES * sizeof(int));

	// First setup the COO format from the input (source_vertices and target_vertices array)
	nvgraphHandle_t handle;
	nvgraphGraphDescr_t graph;
	nvgraphCreate(&handle);
	nvgraphCreateGraphDescr(handle, &graph);
	nvgraphCOOTopology32I_t cooTopology = (nvgraphCOOTopology32I_t)malloc(sizeof(struct nvgraphCOOTopology32I_st));
	cooTopology->nedges = SIZE_EDGES;
	cooTopology->nvertices = SIZE_VERTICES;
	cooTopology->tag = NVGRAPH_UNSORTED;

	gpuErrchk(cudaMalloc((void**)&cooTopology->source_indices, SIZE_EDGES * sizeof(int)));
	gpuErrchk(cudaMalloc((void**)&cooTopology->destination_indices, SIZE_EDGES * sizeof(int)));

	gpuErrchk(cudaMemcpy(cooTopology->source_indices, source_vertices, SIZE_EDGES * sizeof(int), cudaMemcpyHostToDevice));
	gpuErrchk(cudaMemcpy(cooTopology->destination_indices, target_vertices, SIZE_EDGES * sizeof(int), cudaMemcpyHostToDevice));

	// Edge data (allocated, but not used)
	cudaDataType_t data_type = CUDA_R_32F;
	float* d_edge_data;
	float* d_destination_edge_data;
	gpuErrchk(cudaMalloc((void**)&d_edge_data, sizeof(float) * SIZE_EDGES)); // Note: only allocate this for 1 float since we don't have any data yet
	gpuErrchk(cudaMalloc((void**)&d_destination_edge_data, sizeof(float) * SIZE_EDGES)); // Note: only allocate this for 1 float since we don't have any data yet

	nvgraphCSRTopology32I_t csrTopology = (nvgraphCSRTopology32I_t)malloc(sizeof(struct nvgraphCSRTopology32I_st));
	int **d_indices = &(csrTopology->destination_indices);
	int **d_offsets = &(csrTopology->source_offsets);

	gpuErrchk(cudaMalloc((void**)d_indices, SIZE_EDGES * sizeof(int)));
	gpuErrchk(cudaMalloc((void**)d_offsets, (SIZE_VERTICES + 1) * sizeof(int)));

	check(nvgraphConvertTopology(handle, NVGRAPH_COO_32, cooTopology, d_edge_data, &data_type, NVGRAPH_CSR_32, csrTopology, d_destination_edge_data));

	gpuErrchk(cudaPeekAtLastError());

	// Copy data to the host (without edge data)
	gpuErrchk(cudaMemcpy(csr_list->indices, *d_indices, SIZE_EDGES * sizeof(int), cudaMemcpyDeviceToHost));
	gpuErrchk(cudaMemcpy(csr_list->offsets, *d_offsets, (SIZE_VERTICES + 1) * sizeof(int), cudaMemcpyDeviceToHost));

	// Clean up (Data allocated on device and both topologies, since we only want to work with indices and offsets for now)
	cudaFree(d_indices);
	cudaFree(d_offsets);
	cudaFree(d_edge_data);
	cudaFree(d_destination_edge_data);
	cudaFree(cooTopology->destination_indices);
	cudaFree(cooTopology->source_indices);
	free(cooTopology);
	free(csrTopology);

	return csr_list;
}

int get_thread_size() {
	return ((SIZE_VERTICES + 1) > MAX_THREADS) ? MAX_THREADS : SIZE_VERTICES;
}

int get_block_size() {
	return ((SIZE_VERTICES + 1) > MAX_THREADS) ? ((SIZE_VERTICES / MAX_THREADS) + 1) : 1;
}

int calculate_node_sampled_size(float fraction) {
	return int(SIZE_VERTICES * fraction);
}

/*
NOTE: Only reads integer vertices for now (through the 'sscanf' function) and obvious input vertices arrays
*/
void load_graph_from_edge_list_file(int* source_vertices, int* target_vertices, char* file_path) {
	printf("\nLoading graph file from: %s", file_path);

	FILE* file = fopen(file_path, "r");
	char line[256];
	int edge_index = 0;

	while (fgets(line, sizeof(line), file)) {
		if (line[0] == '#') {
			//print_debug_log("\nEscaped a comment.");
			continue;
		}

		// Save source and target vertex (temp)
		int source_vertex;
		int target_vertex;

		sscanf(line, "%d%d\t", &source_vertex, &target_vertex);

		// Add vertices to the source and target arrays, forming an edge accordingly
		source_vertices[edge_index] = source_vertex;
		target_vertices[edge_index] = target_vertex;

		// Increment edge index to add any new edge
		edge_index++;

		//print_debug_log("\nAdded start vertex:", source_vertex);
		//print_debug_log("\nAdded end vertex:", target_vertex);
	}

	fclose(file);
}

COO_List* load_graph_from_edge_list_file_to_coo(std::vector<int>& source_vertices, std::vector<int>& destination_vertices, char* file_path) {
	printf("\nLoading graph file from: %s", file_path);

	FILE* file = fopen(file_path, "r");

	char line[256];

	int current_coordinate = 0;
	if (IS_INPUT_FILE_COO) { // Saves many 'if' ticks inside the while loop - If the input file is already a COO, simply add the coordinates the vectors.
		std::unordered_set<int> vertices;
		
		while (fgets(line, sizeof(line), file)) {
			if (line[0] == '#' || line[0] == '\n') {
				//print_debug_log("\nEscaped a comment.");
				continue;
			}

			// Save source and target vertex (temp)
			int source_vertex;
			int target_vertex;

			sscanf(line, "%d%d\t", &source_vertex, &target_vertex);

			// Add vertices to the source and target arrays, forming an edge accordingly
			source_vertices.push_back(source_vertex);
			destination_vertices.push_back(target_vertex);
			vertices.insert(source_vertex);
			vertices.insert(target_vertex);
		}

		SIZE_VERTICES = vertices.size();
		SIZE_EDGES = source_vertices.size();

		printf("\nTotal amount of vertices: %zd", SIZE_VERTICES);
		printf("\nTotal amount of edges: %zd", SIZE_EDGES);
	} else {
		std::unordered_map<int, int> map_from_edge_to_coordinate;

		while (fgets(line, sizeof(line), file)) {
			if (line[0] == '#' || line[0] == '\n') {
				//print_debug_log("\nEscaped a comment.");
				continue;
			}

			// Save source and target vertex (temp)
			int source_vertex;
			int target_vertex;

			sscanf(line, "%d%d\t", &source_vertex, &target_vertex);

			// Add vertices to the source and target arrays, forming an edge accordingly
			current_coordinate = add_vertex_as_coordinate(source_vertices, map_from_edge_to_coordinate, source_vertex, current_coordinate);
			current_coordinate = add_vertex_as_coordinate(destination_vertices, map_from_edge_to_coordinate, target_vertex, current_coordinate);
		}

		SIZE_VERTICES = map_from_edge_to_coordinate.size();
		SIZE_EDGES = source_vertices.size();

		printf("\nTotal amount of vertices: %zd", SIZE_VERTICES);
		printf("\nTotal amount of edges: %zd", SIZE_EDGES);
	}

	COO_List* coo_list = (COO_List*)malloc(sizeof(COO_List));

	source_vertices.reserve(source_vertices.size());
	destination_vertices.reserve(destination_vertices.size());
	coo_list->source = &source_vertices[0];
	coo_list->destination = &destination_vertices[0];

	if (source_vertices.size() != destination_vertices.size()) {
		printf("\nThe size of the source vertices does not equal the destination vertices.");
		exit(1);
	}

	bool SAVE_INPUT_FILE_AS_COO = false;
	if (SAVE_INPUT_FILE_AS_COO) {
		save_input_file_as_coo(source_vertices, destination_vertices, "C:\\Users\\AJ\\Desktop\\new_datasets\\coo\\none.txt");
	}

	// Print edges
	/*for (int i = 0; i < source_vertices.size(); i++) {
	printf("\n(%d, %d)", coo_list->source[i], coo_list->destination[i]);
	}*/

	fclose(file);

	return coo_list;
}

int add_vertex_as_coordinate(std::vector<int>& vertices_type, std::unordered_map<int, int>& map_from_edge_to_coordinate, int vertex, int coordinate) {
	if (map_from_edge_to_coordinate.count(vertex)) {
		vertices_type.push_back(map_from_edge_to_coordinate.at(vertex));

		return coordinate;
	}
	else {
		map_from_edge_to_coordinate[vertex] = coordinate;
		vertices_type.push_back(coordinate);
		coordinate++;

		return coordinate;
	}
}

Sampled_Vertices* perform_edge_based_node_sampling_step(int* source_vertices, int* target_vertices, float fraction) {
	printf("\nPerforming edge based node sampling step.\n");

	Sampled_Vertices* sampled_vertices = (Sampled_Vertices*)malloc(sizeof(Sampled_Vertices));

	int amount_total_sampled_vertices = calculate_node_sampled_size(fraction);

	std::random_device seeder;
	std::mt19937 engine(seeder());

	sampled_vertices->vertices = (int*)calloc(SIZE_VERTICES, sizeof(int));
	int collected_amount = 0;

	while (collected_amount < amount_total_sampled_vertices) {
		// Pick a random vertex u
		std::uniform_int_distribution<int> range_edges(0, (SIZE_EDGES - 1)); // Don't select the last element in the offset
		int random_edge_index = range_edges(engine);
		
		// Insert u, v (TODO: extract to method per vertex)
		if (!sampled_vertices->vertices[source_vertices[random_edge_index]]) {
			sampled_vertices->vertices[source_vertices[random_edge_index]] = 1;
			print_debug_log("\nCollected vertex:", source_vertices[random_edge_index]);
			//printf("\nCollected vertex: %d", source_vertices[random_edge_index]);
			collected_amount++;
		}
		if (!sampled_vertices->vertices[target_vertices[random_edge_index]]) {
			sampled_vertices->vertices[target_vertices[random_edge_index]] = 1;
			print_debug_log("\nCollected vertex:", target_vertices[random_edge_index]);
			//printf("\nCollected vertex: %d", target_vertices[random_edge_index]);
			collected_amount++;
		}
	}

	sampled_vertices->sampled_vertices_size = collected_amount;

	printf("\nDone with node sampling step..");

	return sampled_vertices;
}

/*
=======================================================================================
Expanding code
=======================================================================================
*/

void expand_graph(char* input_path, char* output_path, float scaling_factor) {
	std::vector<int> source_vertices;
	std::vector<int> destination_vertices;
	COO_List* coo_list = load_graph_from_edge_list_file_to_coo(source_vertices, destination_vertices, input_path);
	CSR_List* csr_list = convert_coo_to_csr_format(coo_list->source, coo_list->destination);

	const int amount_of_sampled_graphs = scaling_factor / SAMPLING_FRACTION;
	printf("Amount of sampled graph versions: %d", amount_of_sampled_graphs);

	Sampled_Vertices** sampled_vertices_per_graph = (Sampled_Vertices**)malloc(sizeof(Sampled_Vertices)*amount_of_sampled_graphs);

	int** d_size_collected_edges = (int**)malloc(sizeof(int*)*amount_of_sampled_graphs);
	Edge** d_edge_data_expanding = (Edge**)malloc(sizeof(Edge*)*amount_of_sampled_graphs);

	Sampled_Graph_Version* sampled_graph_version_list = new Sampled_Graph_Version[amount_of_sampled_graphs];
	char current_label = 'a';

	// Sequential version
	for (int i = 0; i < amount_of_sampled_graphs; i++) {
		sampled_vertices_per_graph[i] = perform_edge_based_node_sampling_step(coo_list->source, coo_list->destination, SAMPLING_FRACTION);
		printf("\nCollected %d vertices.", sampled_vertices_per_graph[i]->sampled_vertices_size);
		
		std::vector<Edge> edges;
		perform_sequential_induction_step(sampled_vertices_per_graph[i]->vertices, csr_list->offsets, csr_list->indices, edges);

		Sampled_Graph_Version* sampled_graph_version = new Sampled_Graph_Version();
		(*sampled_graph_version).edges = edges; // Mweh

		// Label
		sampled_graph_version->label = current_label++;

		// Copy data to the sampled version list
		sampled_graph_version_list[i] = (*sampled_graph_version);

		// Cleanup
		delete(sampled_graph_version);
		free(sampled_vertices_per_graph[i]->vertices);
		free(sampled_vertices_per_graph[i]);
	}
	
	// Parallell version (GPU CODE)
	/*
	int* d_offsets;
	int* d_indices;
	gpuErrchk(cudaMalloc((void**)&d_offsets, sizeof(int)*(SIZE_VERTICES + 1)));
	gpuErrchk(cudaMalloc((void**)&d_indices, sizeof(int)*SIZE_EDGES));

	gpuErrchk(cudaMemcpyToSymbol(D_SIZE_EDGES, &SIZE_EDGES, sizeof(int), 0, cudaMemcpyHostToDevice));
	gpuErrchk(cudaMemcpyToSymbol(D_SIZE_VERTICES, &SIZE_VERTICES, sizeof(int), 0, cudaMemcpyHostToDevice));

	for (int i = 0; i < amount_of_sampled_graphs; i++) {
		sampled_vertices_per_graph[i] = perform_edge_based_node_sampling_step(coo_list->source, coo_list->destination, SAMPLING_FRACTION);
		printf("\nCollected %d vertices.", sampled_vertices_per_graph[i]->sampled_vertices_size);

		gpuErrchk(cudaMemcpy(d_indices, csr_list->indices, SIZE_EDGES * sizeof(int), cudaMemcpyHostToDevice));
		gpuErrchk(cudaMemcpy(d_offsets, csr_list->offsets, sizeof(int)*(SIZE_VERTICES + 1), cudaMemcpyHostToDevice));

		int* d_sampled_vertices;
		gpuErrchk(cudaMalloc((void**)&d_sampled_vertices, sizeof(int)*SIZE_VERTICES));
		gpuErrchk(cudaMemcpy(d_sampled_vertices, sampled_vertices_per_graph[i]->vertices, sizeof(int)*(SIZE_VERTICES), cudaMemcpyHostToDevice));

		int* h_size_edges = 0;
		gpuErrchk(cudaMalloc((void**)&d_size_collected_edges[i], sizeof(int)));
		gpuErrchk(cudaMemcpy(d_size_collected_edges[i], &h_size_edges, sizeof(int), cudaMemcpyHostToDevice));

		gpuErrchk(cudaMalloc((void**)&d_edge_data_expanding[i], sizeof(Edge)*SIZE_EDGES));

		cudaDeviceSynchronize(); // This can be deleted - double check

		printf("\nRunning kernel (induction step) with block size %d and thread size %d:", get_block_size(), get_thread_size());
		perform_induction_step_expanding<<<get_block_size(), get_thread_size() >> >(d_sampled_vertices, d_offsets, d_indices, d_edge_data_expanding[i], d_size_collected_edges[i]);

		// Edge size
		int h_size_edges_result;
		gpuErrchk(cudaMemcpy(&h_size_edges_result, d_size_collected_edges[i], sizeof(int), cudaMemcpyDeviceToHost));

		// Edges
		printf("\nh_size_edges: %d", h_size_edges_result);
		Sampled_Graph_Version* sampled_graph_version = new Sampled_Graph_Version();
		(*sampled_graph_version).edges.resize(h_size_edges_result);

		gpuErrchk(cudaMemcpy(&sampled_graph_version->edges[0], d_edge_data_expanding[i], sizeof(Edge)*(h_size_edges_result), cudaMemcpyDeviceToHost));

		// Label
		sampled_graph_version->label = current_label++;

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
	free(csr_list);*/
	
	// For each sampled graph version, copy the data back to the host
	std::vector<Bridge_Edge> bridge_edges;

	switch (SELECTED_TOPOLOGY) {
		case STAR:
			link_using_star_topology(sampled_graph_version_list, amount_of_sampled_graphs, bridge_edges);
			break;
		case CHAIN:
			link_using_line_topology(sampled_graph_version_list, amount_of_sampled_graphs, bridge_edges);
			break;
		case CIRCLE:
			link_using_circle_topology(sampled_graph_version_list, amount_of_sampled_graphs, bridge_edges);
			break;
		case MESH:
			link_using_mesh_topology(sampled_graph_version_list, amount_of_sampled_graphs, bridge_edges);
	}

	printf("\nConnected by adding a total of %d bridge edges.", bridge_edges.size());

	write_expanded_output_to_file(sampled_graph_version_list, amount_of_sampled_graphs, bridge_edges, output_path);

	// Cleanup
	delete[] sampled_graph_version_list;
}

void link_using_star_topology(Sampled_Graph_Version* sampled_graph_version_list, int amount_of_sampled_graphs, std::vector<Bridge_Edge>& bridge_edges) {
	Sampled_Graph_Version center_graph = sampled_graph_version_list[0]; // First sampled version will be the graph in the center

	for (int i = 1; i < amount_of_sampled_graphs; i++) { // Skip the center graph 
		add_edge_interconnection_between_graphs(&(sampled_graph_version_list[i]), &center_graph, bridge_edges);
	}

}

void link_using_line_topology(Sampled_Graph_Version* sampled_graph_version_list, int amount_of_sampled_graphs, std::vector<Bridge_Edge>& bridge_edges) {
	for (int i = 0; i < (amount_of_sampled_graphs-1); i++) {
		add_edge_interconnection_between_graphs(&(sampled_graph_version_list[i]), &(sampled_graph_version_list[i+1]), bridge_edges);
	}
}

void link_using_circle_topology(Sampled_Graph_Version* sampled_graph_version_list, int amount_of_sampled_graphs, std::vector<Bridge_Edge>& bridge_edges) {
	for (int i = 0; i < amount_of_sampled_graphs; i++) {
		if (i == (amount_of_sampled_graphs-1)) { // We're at the last sampled graph, so connect it back to the first one in the list
			add_edge_interconnection_between_graphs(&(sampled_graph_version_list[i]), &(sampled_graph_version_list[0]), bridge_edges);
			break;
		}

		add_edge_interconnection_between_graphs(&(sampled_graph_version_list[i]), &(sampled_graph_version_list[i+1]), bridge_edges);
	}
}

void link_using_mesh_topology(Sampled_Graph_Version* sampled_graph_version_list, int amount_of_sampled_graphs, std::vector<Bridge_Edge>& bridge_edges) {
	for (int x = 0; x < amount_of_sampled_graphs; x++) {
		Sampled_Graph_Version current_graph = sampled_graph_version_list[x];

		for (int y = 0; y < amount_of_sampled_graphs; y++) {
			if (x==y) { // Don't link the current graph to itself
				continue;
			}

			add_edge_interconnection_between_graphs(&(sampled_graph_version_list[x]), &(sampled_graph_version_list[y]), bridge_edges);
		}
	}
}

/*
-> Probably parallelizable.
-> if(amount_of_edge_interconnections<1) = fraction of the edges/nodes?
*/
void add_edge_interconnection_between_graphs(Sampled_Graph_Version* graph_a, Sampled_Graph_Version* graph_b, std::vector<Bridge_Edge>& bridge_edges) {
	for (int i = 0; i < AMOUNT_INTERCONNECTIONS; i++) {
		int vertex_a = get_node_bridge_vertex(graph_a);
		int vertex_b = get_node_bridge_vertex(graph_b);

		// Add edge
		Bridge_Edge bridge_edge;
		sprintf(bridge_edge.source, "%c%d", graph_a->label, vertex_a);
		sprintf(bridge_edge.destination, "%c%d", graph_b->label, vertex_b);
		bridge_edges.push_back(bridge_edge);
		//printf("\nBridge selection - Selected: (%s, %s)", bridge_edge.source, bridge_edge.destination);

		if (FORCE_UNDIRECTED_BRIDGES) {
			Bridge_Edge bridge_edge_undirected;
			sprintf(bridge_edge_undirected.source, "%c%d", graph_b->label, vertex_b);
			sprintf(bridge_edge_undirected.destination, "%c%d", graph_a->label, vertex_a);
			bridge_edges.push_back(bridge_edge_undirected);
			//printf("\nBridge selection (undirected) - Selected: (%s, %s)", bridge_edge_undirected.source, bridge_edge_undirected.destination);
		}
	}
}

// TODO: Add parameter (e.g. Random/high-degree nodes/low-degree nodes)
int select_random_bridge_vertex(Sampled_Graph_Version* graph) {
	// TODO: Move to add_edge_interconnection_between_graphs
	std::random_device seeder;
	std::mt19937 engine(seeder());
	std::uniform_int_distribution<int> range_edges(0, ((*graph).edges.size()) - 1);
	int random_edge_index = range_edges(engine);

	// 50:50 return source or destination
	std::random_device destination_or_source_seeder;
	std::mt19937 engine_source_or_destination(destination_or_source_seeder());
	std::uniform_int_distribution<int> range_destination_source(0, 1);
	int destination_or_source = range_destination_source(engine_source_or_destination);

	if (destination_or_source == 0) {
		return (*graph).edges[random_edge_index].source; 
	}
	else {
		return (*graph).edges[random_edge_index].destination; 
	}
}

int select_high_degree_node_bridge_vertex(Sampled_Graph_Version* graph) {
	if (graph->high_degree_nodes.size() > 0) { // There already exists some high degree nodes here, so just select them randomly for instance.
		return get_random_high_degree_node(graph);
	} else { // Collect high degree nodes and add them to the current graph
		// Map all vertices onto a map along with their degree
		std::unordered_map<int, int> node_degree;
		
		for (auto &edge : graph->edges) {
			++node_degree[edge.source];
			++node_degree[edge.destination];
		}

		// Convert the map to a vector
		std::vector<std::pair<int, int>> node_degree_vect(node_degree.begin(), node_degree.end());

		// Sort the vector (ascending, high degree nodes are on top)
		std::sort(node_degree_vect.begin(), node_degree_vect.end(), [](const std::pair<int, int> &left, const std::pair<int, int> &right) {
			return left.second > right.second;
		});

		// Collect only the nodes (half of the total nodes) that have a high degree
		for (int i = 0; i < node_degree_vect.size() / 2; i++) {
			graph->high_degree_nodes.push_back(node_degree_vect[i].first);
		}

		return get_random_high_degree_node(graph);
	}
}

int get_random_high_degree_node(Sampled_Graph_Version* graph) {
	std::random_device seeder;
	std::mt19937 engine(seeder());

	std::uniform_int_distribution<int> range_edges(0, (graph->high_degree_nodes.size() - 1));
	int random_vertex_index = range_edges(engine);

	return graph->high_degree_nodes[random_vertex_index];
}

int get_node_bridge_vertex(Sampled_Graph_Version* graph) {
	switch (SELECTED_BRIDGE_NODE_SELECTION) {
		case RANDOM_NODES:
			return select_random_bridge_vertex(graph);
		case HIGH_DEGREE_NODES:
			return select_high_degree_node_bridge_vertex(graph);
	}
}

void write_expanded_output_to_file(Sampled_Graph_Version* sampled_graph_version_list, int amount_of_sampled_graphs, std::vector<Bridge_Edge>& bridge_edges, char* ouput_path) {
	printf("\nWriting results to output file.");

	char* file_path = ouput_path;
	FILE *output_file = fopen(file_path, "w");

	if (output_file == NULL) {
		printf("\nError writing results to output file.");
		exit(1);
	}

	// Write sampled graph versions
	for (int i = 0; i < amount_of_sampled_graphs; i++) {
		for (int p = 0; p < sampled_graph_version_list[i].edges.size(); p++) {
			fprintf(output_file, "\n%c%d\t%c%d", sampled_graph_version_list[i].label, sampled_graph_version_list[i].edges[p].source, sampled_graph_version_list[i].label, sampled_graph_version_list[i].edges[p].destination);
		}
	}

	for (int i = 0; i < bridge_edges.size(); i++) {
		fprintf(output_file, "\n%s\t%s", bridge_edges[i].source, bridge_edges[i].destination);
	}

	fclose(output_file);
}

void write_output_to_file(std::vector<Edge>& results, char* output_path) {
	printf("\nWriting results to output file.");
	
	char* file_path = output_path;
	FILE *output_file = fopen(file_path, "w");

	if (output_file == NULL) {
		printf("\nError writing results to output file.");
		exit(1);
	}

	for (int i = 0; i < results.size(); i++) {
		fprintf(output_file, "%d\t%d\n", results[i].source, results[i].destination);
	}

	fclose(output_file);
}


void save_input_file_as_coo(std::vector<int>& source_vertices, std::vector<int>& destination_vertices, char* save_path) {
	printf("\nWriting results to output file.");

	char* file_path = save_path;
	FILE *output_file = fopen(file_path, "w");

	if (output_file == NULL) {
		printf("\nError writing results to output file.");
		exit(1);
	}

	for (int i = 0; i < source_vertices.size(); i++) {
		fprintf(output_file, "%d\t%d\n", source_vertices[i], destination_vertices[i]);
	}

	fclose(output_file);
}

void print_coo(int* source_vertices, int* end_vertices) {
	for (int i = 0; i < SIZE_EDGES; i++) {
		printf("\n%d, %d", source_vertices[i], end_vertices[i]);
	}
}

void print_csr(int* h_offsets, int* h_indices) {
	printf("\nRow Offsets (Vertex Table):\n");
	for (int i = 0; i < SIZE_VERTICES + 1; i++) {
		printf("%d, ", h_offsets[i]);
	}

	printf("\nColumn Indices (Edge Table):\n");
	for (int i = 0; i < SIZE_EDGES; i++) {
		printf("%d, ", h_indices[i]);
	}
}

void check(nvgraphStatus_t status) {
	if (status == NVGRAPH_STATUS_NOT_INITIALIZED) {
		printf("\nError converting to CSR: %d - NVGRAPH_STATUS_NOT_INITIALIZED", status);
		exit(0);
	}
	else if (status == NVGRAPH_STATUS_ALLOC_FAILED) {
		printf("\nError converting to CSR: %d - NVGRAPH_STATUS_ALLOC_FAILED", status);
		exit(0);
	}
	else if (status == NVGRAPH_STATUS_INVALID_VALUE) {
		printf("\nError converting to CSR: %d - NVGRAPH_STATUS_INVALID_VALUE", status);
		exit(0);
	}
	else if (status == NVGRAPH_STATUS_INTERNAL_ERROR) {
		printf("\nError converting to CSR: %d - NVGRAPH_STATUS_INTERNAL_ERROR", status);
		exit(0);
	}
	else if (status == NVGRAPH_STATUS_SUCCESS) {
		printf("\nConverted to CSR successfully (statuscode %d).\n", status);
	}
	else {
		printf("\nSome other error occurred while trying to convert to CSR.");
		exit(0);
	}
}

void print_debug_log(char* message) {
	if (ENABLE_DEBUG_LOG)
		printf("%s", message);
}

void print_debug_log(char* message, int value) {
	if (ENABLE_DEBUG_LOG)
		printf("%s %d", message, value);
}