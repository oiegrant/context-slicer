package com.contextslice.adapter.static_analysis;

import org.eclipse.jdt.core.dom.*;

import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * Wrapper around Eclipse JDT's ASTParser.
 * Parses a set of Java source files with type binding resolution enabled.
 */
public class JdtAstParser {

    private final SourceRoots sourceRoots;

    public JdtAstParser(SourceRoots sourceRoots) {
        this.sourceRoots = sourceRoots;
    }

    /**
     * Parse all .java files under the source root.
     * Returns a map of absolute file path -> CompilationUnit.
     */
    public Map<String, CompilationUnit> parseAll() {
        List<String> sourceFiles = collectSourceFiles(sourceRoots.sourceRoot());
        return parseFiles(sourceFiles);
    }

    /**
     * Parse a specific list of source files.
     */
    public Map<String, CompilationUnit> parseFiles(List<String> absoluteFilePaths) {
        if (absoluteFilePaths.isEmpty()) return Collections.emptyMap();

        ASTParser parser = ASTParser.newParser(AST.JLS21);
        parser.setKind(ASTParser.K_COMPILATION_UNIT);
        parser.setResolveBindings(true);
        parser.setBindingsRecovery(true);
        parser.setStatementsRecovery(true);

        String[] encodings = new String[absoluteFilePaths.size()];
        Arrays.fill(encodings, "UTF-8");

        String[] sourcepathEntries = { sourceRoots.sourceRoot() };
        String[] classpathEntries = sourceRoots.classpathJars().toArray(new String[0]);

        parser.setEnvironment(classpathEntries, sourcepathEntries, new String[]{"UTF-8"}, true);

        Map<String, CompilationUnit> result = new LinkedHashMap<>();

        parser.createASTs(
            absoluteFilePaths.toArray(new String[0]),
            encodings,
            new String[0],
            new FileASTRequestor() {
                @Override
                public void acceptAST(String sourceFilePath, CompilationUnit ast) {
                    result.put(sourceFilePath, ast);
                }
            },
            null
        );

        return result;
    }

    private List<String> collectSourceFiles(String sourceRoot) {
        Path root = Paths.get(sourceRoot);
        if (!root.toFile().exists()) return Collections.emptyList();
        try (Stream<Path> walk = Files.walk(root)) {
            return walk
                .filter(p -> p.toString().endsWith(".java"))
                .map(Path::toAbsolutePath)
                .map(Path::toString)
                .sorted()
                .collect(Collectors.toList());
        } catch (IOException e) {
            System.err.println("[adapter] Warning: could not walk source tree: " + e.getMessage());
            return Collections.emptyList();
        }
    }
}
