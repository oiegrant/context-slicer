package com.contextslice.adapter.ir;

import com.google.gson.annotations.SerializedName;
import java.util.Collections;
import java.util.List;

/**
 * Deserialized form of runtime_trace.json written by the ByteBuddy agent.
 */
public class RuntimeTrace {

    @SerializedName("observed_symbols")
    public List<ObservedSymbol> observedSymbols;

    @SerializedName("observed_edges")
    public List<ObservedEdge> observedEdges;

    @SerializedName("config_reads")
    public List<ConfigRead> configReads;

    public List<ObservedSymbol> getObservedSymbols() {
        return observedSymbols != null ? observedSymbols : Collections.emptyList();
    }

    public List<ObservedEdge> getObservedEdges() {
        return observedEdges != null ? observedEdges : Collections.emptyList();
    }

    public List<ConfigRead> getConfigReads() {
        return configReads != null ? configReads : Collections.emptyList();
    }

    public static class ObservedSymbol {
        @SerializedName("symbol_id")  public String symbolId;
        @SerializedName("call_count") public long callCount;
    }

    public static class ObservedEdge {
        @SerializedName("caller")     public String caller;
        @SerializedName("callee")     public String callee;
        @SerializedName("call_count") public long callCount;
    }

    public static class ConfigRead {
        @SerializedName("symbol_id")      public String symbolId;
        @SerializedName("config_key")     public String configKey;
        @SerializedName("resolved_value") public String resolvedValue;
    }
}
