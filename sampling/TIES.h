/*
- Created by Ahmed on 12-11-17.

Implementation of Total Induced Edge Sampling
*/

#ifndef GRAPH_SCALING_TOOL_TIES_H
#define GRAPH_SCALING_TOOL_TIES_H

#include <iostream>
#include "Sampling.h"

class TIES : public Sampling {
private:
    void performEdgeBasedNodeSamplingStep(std::unordered_set<int>& sampledVertices, float fraction);
    std::vector<Edge> performInductionStep(std::unordered_set<int>& sampledVertices, std::vector<Edge>& sampledEdges);
    bool isVertexInSampledVertices(int vertex, std::unordered_set<int> &sampledVertices);
    Edge getRandomEdge();

public:
    TIES(Graph* graph) : Sampling(graph) {};
    void sample(float fraction);
};


#endif //GRAPH_SCALING_TOOL_TIES_H
