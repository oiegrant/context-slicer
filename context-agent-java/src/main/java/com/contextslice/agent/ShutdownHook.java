package com.contextslice.agent;

import com.google.gson.GsonBuilder;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Collectors;

/**
 * Serializes all RuntimeTracer data to runtime_trace.json on JVM shutdown.
 * Registered via Runtime.getRuntime().addShutdownHook().
 */
public class ShutdownHook implements Runnable {

    private final Path outputPath;

    public ShutdownHook(Path outputPath) {
        this.outputPath = outputPath;
    }

    @Override
    public void run() {
        try {
            RuntimeTrace trace = buildTrace();
            write(trace);
        } catch (Exception e) {
            System.err.println("[context-agent] ERROR writing runtime_trace.json: " + e.getMessage());
        }
    }

    RuntimeTrace buildTrace() {
        RuntimeTrace trace = new RuntimeTrace();

        // Observed symbols — sorted by symbolId for determinism
        trace.observedSymbols = RuntimeTracer.methodCounts.entrySet().stream()
            .map(e -> {
                RuntimeTrace.ObservedSymbol s = new RuntimeTrace.ObservedSymbol();
                s.symbolId = e.getKey();
                s.callCount = e.getValue().sum();
                return s;
            })
            .sorted(Comparator.comparing(s -> s.symbolId))
            .collect(Collectors.toList());

        // Observed edges — read directly from EdgeKey records; no string splitting needed
        trace.observedEdges = RuntimeTracer.edgeCounts.entrySet().stream()
            .map(e -> {
                RuntimeTrace.ObservedEdge edge = new RuntimeTrace.ObservedEdge();
                edge.caller = e.getKey().caller();
                edge.callee = e.getKey().callee();
                edge.callCount = e.getValue().sum();
                return edge;
            })
            .sorted(Comparator.comparing((RuntimeTrace.ObservedEdge e) -> e.caller)
                              .thenComparing(e -> e.callee))
            .collect(Collectors.toList());

        return trace;
    }

    void write(RuntimeTrace trace) throws IOException {
        Files.createDirectories(outputPath.getParent() != null ? outputPath.getParent() : Path.of("."));
        try (Writer w = new FileWriter(outputPath.toFile())) {
            new GsonBuilder().setPrettyPrinting().create().toJson(trace, w);
        }
        System.err.println("[context-agent] runtime_trace.json written: " + outputPath);
    }
}
