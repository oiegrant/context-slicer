package com.contextslice.adapter.manifest;

import com.google.gson.annotations.SerializedName;
import java.util.Collections;
import java.util.List;

/**
 * Deserialized form of the manifest.json written by the Zig orchestrator.
 */
public class ManifestConfig {

    @SerializedName("scenario_name")
    private String scenarioName;

    @SerializedName("entry_points")
    private List<String> entryPoints;

    @SerializedName("run_args")
    private List<String> runArgs;

    @SerializedName("config_files")
    private List<String> configFiles;

    @SerializedName("output_dir")
    private String outputDir;

    /**
     * Optional shell command to run after the server is ready.
     * If non-null, adapter starts the app, waits for readiness, runs this script,
     * then sends SIGTERM to trigger shutdown.
     * If null, the adapter waits for the app to exit on its own.
     */
    @SerializedName("run_script")
    private String runScript;

    /** Optional server port for readiness polling (default: 8080). */
    @SerializedName("server_port")
    private Integer serverPort;

    /** Optional namespace filter for ByteBuddy agent (default: "com."). */
    @SerializedName("namespace")
    private String namespace;

    public String getScenarioName() { return scenarioName; }
    public List<String> getEntryPoints() { return entryPoints != null ? entryPoints : Collections.emptyList(); }
    public List<String> getRunArgs()     { return runArgs     != null ? runArgs     : Collections.emptyList(); }
    public List<String> getConfigFiles() { return configFiles != null ? configFiles : Collections.emptyList(); }
    public String getOutputDir()         { return outputDir; }
    public String getRunScript()         { return runScript; }
    public int getServerPort()           { return serverPort != null ? serverPort : 8080; }
    public String getNamespace()         { return namespace != null ? namespace : "com."; }
}
