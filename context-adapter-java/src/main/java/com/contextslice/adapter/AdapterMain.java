package com.contextslice.adapter;

import com.contextslice.adapter.build.BuildRunner;
import com.contextslice.adapter.ir.IrMerger;
import com.contextslice.adapter.ir.IrModel;
import com.contextslice.adapter.ir.IrSerializer;
import com.contextslice.adapter.ir.RuntimeTrace;
import com.contextslice.adapter.manifest.ManifestConfig;
import com.contextslice.adapter.manifest.ManifestReader;
import com.contextslice.adapter.runtime.AgentLauncher;
import com.contextslice.adapter.static_analysis.StaticAnalyzer;
import com.contextslice.adapter.static_analysis.StaticIr;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Collections;

/**
 * Entry point for the context-adapter-java subprocess.
 *
 * Usage:
 *   java -jar context-adapter-java.jar record \
 *     --manifest <path-to-manifest.json> \
 *     --output   <output-dir> \
 *     --agent    <path-to-context-agent-java.jar>
 */
public class AdapterMain {

    public static void main(String[] args) {
        try {
            run(args);
            System.exit(0);
        } catch (UsageException e) {
            System.err.println("[context-adapter] ERROR: " + e.getMessage());
            System.err.println("Usage: java -jar context-adapter-java.jar record " +
                               "--manifest <path> --output <dir> --agent <jar>");
            System.exit(2);
        } catch (Exception e) {
            System.err.println("[context-adapter] FATAL: " + e.getMessage());
            System.exit(1);
        }
    }

    static void run(String[] args) {
        if (args.length == 0) {
            throw new UsageException("No subcommand specified");
        }
        if (!args[0].equals("record")) {
            throw new UsageException("Unknown subcommand: " + args[0]);
        }

        // Parse flags
        String manifestPath = null;
        String outputDir = null;
        String agentJar = null;
        String namespace = "com.";

        for (int i = 1; i < args.length; i++) {
            switch (args[i]) {
                case "--manifest" -> manifestPath = requireNext(args, i++, "--manifest");
                case "--output"   -> outputDir   = requireNext(args, i++, "--output");
                case "--agent"    -> agentJar     = requireNext(args, i++, "--agent");
                case "--namespace"-> namespace    = requireNext(args, i++, "--namespace");
                default -> throw new UsageException("Unknown flag: " + args[i]);
            }
        }

        if (manifestPath == null) throw new UsageException("--manifest is required");
        if (outputDir == null)    throw new UsageException("--output is required");
        if (agentJar == null)     throw new UsageException("--agent is required");
        final String effectiveNamespace = namespace;  // may be overridden by manifest

        Path manifest = Paths.get(manifestPath);
        Path output   = Paths.get(outputDir);
        Path agent    = Paths.get(agentJar);

        // 1. Read manifest
        System.err.println("[context-adapter] Reading manifest: " + manifest);
        ManifestConfig config = new ManifestReader().read(manifest);

        // Project root = directory containing manifest.json
        Path projectRoot = manifest.toAbsolutePath().getParent();
        String scenarioName = config.getScenarioName() != null ? config.getScenarioName() : "unknown";

        // 2. Static analysis
        System.err.println("[context-adapter] Running static analysis on: " + projectRoot);
        StaticIr staticIr = new StaticAnalyzer().analyze(projectRoot, config);
        System.err.println("[context-adapter] Static analysis complete: "
                + staticIr.symbols().size() + " symbols, "
                + staticIr.callEdges().size() + " edges");

        // 3. Build the target project
        System.err.println("[context-adapter] Building project...");
        Path appJar = new BuildRunner().build(projectRoot);
        System.err.println("[context-adapter] Built JAR: " + appJar);

        // Use manifest namespace if CLI arg was the default
        String resolvedNamespace = effectiveNamespace.equals("com.") && config.getNamespace() != null
                ? config.getNamespace()
                : effectiveNamespace;

        // 4. Launch with agent
        System.err.println("[context-adapter] Launching with agent for runtime trace...");
        RuntimeTrace runtimeTrace = new AgentLauncher().launch(
                agent,
                appJar,
                output.resolve("runtime"),
                resolvedNamespace,
                config.getRunArgs().isEmpty() ? Collections.emptyList() : config.getRunArgs(),
                config.getRunScript(),
                config.getServerPort()
        );
        System.err.println("[context-adapter] Runtime trace complete: "
                + runtimeTrace.getObservedSymbols().size() + " observed symbols");

        // 5. Merge
        System.err.println("[context-adapter] Merging static IR and runtime trace...");
        IrModel.IrRoot merged = new IrMerger().merge(
                staticIr,
                runtimeTrace,
                scenarioName,
                config.getEntryPoints(),
                projectRoot.toString()
        );

        // 6. Serialize
        System.err.println("[context-adapter] Writing output to: " + output);
        new IrSerializer().write(merged, output, scenarioName);

        System.err.println("[context-adapter] Done.");
    }

    private static String requireNext(String[] args, int i, String flag) {
        if (i + 1 >= args.length) {
            throw new UsageException(flag + " requires an argument");
        }
        return args[i + 1];
    }

    static class UsageException extends RuntimeException {
        UsageException(String msg) { super(msg); }
    }
}
