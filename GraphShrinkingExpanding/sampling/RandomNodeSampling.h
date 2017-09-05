#pragma once

#include <stdio.h>
#include <math.h>
#include <vector>
#include <random>
#include "../io/GraphIO.h"
#include "SampledVerticesStruct.h"
#include <iterator>

class RandomNodeSampling {
private:
	GraphIO* _graph_io;
public:
	RandomNodeSampling(GraphIO* graph_io);
	float SAMPLING_FRACTION;
	void collect_sampling_parameters(char* argv[]);
	void sample_graph(char* input_path, char* output_path);
	std::unordered_set<int> node_selection_step(std::vector<int>&, std::vector<int>&);
	std::vector<Edge> induction_step(std::vector<int>&, std::vector<int>&, std::unordered_set<int>&);
	int calculate_node_sampled_size();
};