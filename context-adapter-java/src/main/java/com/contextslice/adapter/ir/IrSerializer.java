package com.contextslice.adapter.ir;

import com.google.gson.GsonBuilder;

import java.io.*;
import java.nio.file.*;
import java.time.Instant;
import java.util.Comparator;

/**
 * Sorts and serializes the merged IrRoot to static_ir.json.
 * Produces deterministic output by sorting all arrays by ID before writing.
 */
public class IrSerializer {

    public static class SerializerException extends RuntimeException {
        public SerializerException(String msg, Throwable cause) { super(msg, cause); }
    }

    /**
     * Writes {@code root} to {@code outputDir/static_ir.json} with arrays sorted for determinism.
     * Also writes {@code outputDir/metadata.json} with scenario and adapter info.
     *
     * @param root      merged IR root to write
     * @param outputDir directory to write into (created if absent)
     * @param scenarioName name for metadata.json
     */
    public void write(IrModel.IrRoot root, Path outputDir, String scenarioName) {
        try {
            Files.createDirectories(outputDir);
        } catch (IOException e) {
            throw new SerializerException("Could not create output directory: " + outputDir, e);
        }

        // Copy to mutable lists and sort for determinism
        if (root.symbols != null) {
            root.symbols = new java.util.ArrayList<>(root.symbols);
            root.symbols.sort(Comparator.comparing(s -> s.id));
        }
        if (root.callEdges != null) {
            root.callEdges = new java.util.ArrayList<>(root.callEdges);
            root.callEdges.sort(Comparator.comparing((IrModel.IrCallEdge e) -> e.caller)
                    .thenComparing(e -> e.callee));
        }
        if (root.configReads != null) {
            root.configReads = new java.util.ArrayList<>(root.configReads);
            root.configReads.sort(Comparator.comparing((IrModel.IrConfigRead cr) -> cr.symbolId)
                    .thenComparing(cr -> cr.configKey));
        }
        if (root.files != null) {
            root.files = new java.util.ArrayList<>(root.files);
            root.files.sort(Comparator.comparing(f -> f.path));
        }
        if (root.runtime != null) {
            if (root.runtime.observedSymbols != null) {
                root.runtime.observedSymbols = new java.util.ArrayList<>(root.runtime.observedSymbols);
                root.runtime.observedSymbols.sort(Comparator.comparing(s -> s.symbolId));
            }
            if (root.runtime.observedEdges != null) {
                root.runtime.observedEdges = new java.util.ArrayList<>(root.runtime.observedEdges);
                root.runtime.observedEdges.sort(Comparator.comparing((IrModel.IrObservedEdge e) -> e.caller)
                        .thenComparing(e -> e.callee));
            }
        }

        var gson = new GsonBuilder().setPrettyPrinting().create();

        Path irPath = outputDir.resolve("static_ir.json");
        try (Writer w = new FileWriter(irPath.toFile())) {
            gson.toJson(root, w);
        } catch (IOException e) {
            throw new SerializerException("Failed to write static_ir.json: " + e.getMessage(), e);
        }
        System.err.println("[context-adapter] static_ir.json written: " + irPath);

        // Write metadata.json
        var meta = new Metadata(scenarioName, "java", "0.1.0", Instant.now().toString());
        Path metaPath = outputDir.resolve("metadata.json");
        try (Writer w = new FileWriter(metaPath.toFile())) {
            gson.toJson(meta, w);
        } catch (IOException e) {
            throw new SerializerException("Failed to write metadata.json: " + e.getMessage(), e);
        }
        System.err.println("[context-adapter] metadata.json written: " + metaPath);
    }

    /** Simple metadata record for Gson serialization. */
    private record Metadata(
            String scenarioName,
            String language,
            String adapterVersion,
            String timestamp
    ) {}
}
