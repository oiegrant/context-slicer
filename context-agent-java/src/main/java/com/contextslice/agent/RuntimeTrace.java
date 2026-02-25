package com.contextslice.agent;

import com.google.gson.annotations.SerializedName;
import java.util.List;

/**
 * POJO written to runtime_trace.json by ShutdownHook.
 * Matches the "runtime" block of the IR schema v0.1.
 */
public class RuntimeTrace {

    @SerializedName("observed_symbols")
    public List<ObservedSymbol> observedSymbols;

    @SerializedName("observed_edges")
    public List<ObservedEdge> observedEdges;

    @SerializedName("method_transforms")
    public List<TransformRecord> methodTransforms;

    public static class ObservedSymbol {
        @SerializedName("symbol_id")  public String symbolId;
        @SerializedName("call_count") public long callCount;
    }

    public static class ObservedEdge {
        @SerializedName("caller")     public String caller;
        @SerializedName("callee")     public String callee;
        @SerializedName("call_count") public long callCount;
    }

}
