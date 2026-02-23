package com.contextslice.adapter.ir;

import com.google.gson.annotations.SerializedName;
import java.util.List;

/**
 * POJOs matching IR schema v0.1.
 * Field names use @SerializedName for JSON snake_case mapping.
 */
public final class IrModel {

    private IrModel() {}

    public static class IrRoot {
        @SerializedName("ir_version")      public String irVersion;
        @SerializedName("language")        public String language;
        @SerializedName("repo_root")       public String repoRoot;
        @SerializedName("build_id")        public String buildId;
        @SerializedName("adapter_version") public String adapterVersion;
        @SerializedName("scenario")        public IrScenario scenario;
        @SerializedName("files")           public List<IrFile> files;
        @SerializedName("symbols")         public List<IrSymbol> symbols;
        @SerializedName("call_edges")      public List<IrCallEdge> callEdges;
        @SerializedName("runtime")         public IrRuntime runtime;
    }

    public static class IrScenario {
        @SerializedName("name")          public String name;
        @SerializedName("entry_points")  public List<String> entryPoints;
        @SerializedName("run_args")      public List<String> runArgs;
        @SerializedName("config_files")  public List<String> configFiles;
    }

    public static class IrFile {
        @SerializedName("id")       public String id;
        @SerializedName("path")     public String path;
        @SerializedName("language") public String language;
        @SerializedName("hash")     public String hash;
    }

    public static class IrSymbol {
        @SerializedName("id")             public String id;
        @SerializedName("kind")           public String kind;       // class, method, constructor, interface
        @SerializedName("name")           public String name;
        @SerializedName("language")       public String language;
        @SerializedName("file_id")        public String fileId;
        @SerializedName("line_start")     public int lineStart;
        @SerializedName("line_end")       public int lineEnd;
        @SerializedName("visibility")     public String visibility;
        @SerializedName("container")      public String container;  // nullable
        @SerializedName("annotations")    public List<String> annotations;
        @SerializedName("is_entry_point") public boolean isEntryPoint;
        @SerializedName("is_framework")   public boolean isFramework;
        @SerializedName("is_generated")   public boolean isGenerated;
    }

    public static class IrCallEdge {
        @SerializedName("caller")           public String caller;
        @SerializedName("callee")           public String callee;
        @SerializedName("static")           public boolean isStatic;
        @SerializedName("runtime_observed") public boolean runtimeObserved;
        @SerializedName("call_count")       public long callCount;
    }

    public static class IrRuntime {
        @SerializedName("observed_symbols") public List<IrObservedSymbol> observedSymbols;
        @SerializedName("observed_edges")   public List<IrObservedEdge> observedEdges;
    }

    public static class IrObservedSymbol {
        @SerializedName("symbol_id")  public String symbolId;
        @SerializedName("call_count") public long callCount;
    }

    public static class IrObservedEdge {
        @SerializedName("caller")     public String caller;
        @SerializedName("callee")     public String callee;
        @SerializedName("call_count") public long callCount;
    }
}
