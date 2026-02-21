package com.contextslice.adapter.static_analysis;

import com.contextslice.adapter.ir.IrModel.*;
import com.contextslice.adapter.manifest.ManifestConfig;
import org.eclipse.jdt.core.dom.CompilationUnit;

import java.nio.file.*;
import java.util.*;

/**
 * Orchestrates the full static analysis pass.
 * Produces a StaticIr aggregate from the project's source files.
 */
public class StaticAnalyzer {

    private final AnnotationProcessor annotationProcessor = new AnnotationProcessor();

    public StaticIr analyze(Path projectRoot, ManifestConfig manifest) {
        // 1. Resolve source roots and classpath
        SourceRootResolver resolver = new SourceRootResolver();
        SourceRoots sourceRoots = resolver.resolve(projectRoot);

        // 2. Parse AST with type bindings
        JdtAstParser parser = new JdtAstParser(sourceRoots);
        Map<String, CompilationUnit> compilationUnits = parser.parseAll();

        // 3. Build file ID map (relative path -> file id)
        List<IrFile> files = new ArrayList<>();
        Map<String, String> filePathToId = new LinkedHashMap<>();
        int fileIndex = 1;
        for (String absolutePath : compilationUnits.keySet()) {
            String relativePath = makeRelative(projectRoot.toAbsolutePath().toString(), absolutePath);
            String fileId = String.format("f%02d", fileIndex++);
            IrFile irFile = new IrFile();
            irFile.id = fileId;
            irFile.path = relativePath;
            irFile.language = "java";
            irFile.hash = "sha256:"; // TODO: compute real hash in later phase
            files.add(irFile);
            filePathToId.put(absolutePath, fileId);
        }

        // 4. Extract symbols and call edges from each compilation unit
        List<IrSymbol> allSymbols = new ArrayList<>();
        List<IrCallEdge> allEdges = new ArrayList<>();

        for (Map.Entry<String, CompilationUnit> entry : compilationUnits.entrySet()) {
            String absolutePath = entry.getKey();
            CompilationUnit cu = entry.getValue();
            String fileId = filePathToId.get(absolutePath);

            SymbolExtractor symbolExtractor = new SymbolExtractor(fileId, manifest.getEntryPoints());
            cu.accept(symbolExtractor);
            allSymbols.addAll(symbolExtractor.getSymbols());

            CallEdgeExtractor callExtractor = new CallEdgeExtractor();
            cu.accept(callExtractor);
            allEdges.addAll(callExtractor.getEdges());
        }

        // 5. Apply annotation processor (marks isFramework)
        annotationProcessor.process(allSymbols);

        // 6. Filter call edges to only reference known symbol IDs
        Set<String> knownIds = new HashSet<>();
        for (IrSymbol s : allSymbols) knownIds.add(s.id);
        List<IrCallEdge> filteredEdges = new ArrayList<>();
        for (IrCallEdge edge : allEdges) {
            if (knownIds.contains(edge.caller) && knownIds.contains(edge.callee)) {
                filteredEdges.add(edge);
            }
        }

        return new StaticIr(files, allSymbols, filteredEdges);
    }

    private String makeRelative(String projectRoot, String absolutePath) {
        if (absolutePath.startsWith(projectRoot)) {
            String rel = absolutePath.substring(projectRoot.length());
            return rel.startsWith("/") ? rel.substring(1) : rel;
        }
        return absolutePath;
    }
}
