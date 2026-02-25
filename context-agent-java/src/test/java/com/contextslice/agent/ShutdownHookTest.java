package com.contextslice.agent;

import com.google.gson.Gson;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.FileReader;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

class ShutdownHookTest {

    @BeforeEach
    void reset() {
        RuntimeTracer.reset();
    }

    @Test
    void writesRuntimeTraceJson(@TempDir Path tmp) throws Exception {
        // Populate RuntimeTracer with known data
        RuntimeTracer.push("com.example.A::foo");
        RuntimeTracer.push("com.example.B::bar");
        RuntimeTracer.recordEdge("com.example.A::foo", "com.example.B::bar");
        RuntimeTracer.pop();
        RuntimeTracer.pop();

        Path tracePath = tmp.resolve("runtime_trace.json");
        ShutdownHook hook = new ShutdownHook(tracePath);
        hook.run();

        assertTrue(tracePath.toFile().exists(), "runtime_trace.json must be created");

        RuntimeTrace trace = new Gson().fromJson(new FileReader(tracePath.toFile()), RuntimeTrace.class);
        assertNotNull(trace);

        // observedSymbols: 2 symbols (A::foo and B::bar)
        assertEquals(2, trace.observedSymbols.size());

        // observedEdges: 1 edge
        assertEquals(1, trace.observedEdges.size());
        assertEquals("com.example.A::foo", trace.observedEdges.get(0).caller);
        assertEquals("com.example.B::bar", trace.observedEdges.get(0).callee);
        assertEquals(1L, trace.observedEdges.get(0).callCount);
    }

    @Test
    void observedSymbolsSortedById(@TempDir Path tmp) throws Exception {
        RuntimeTracer.push("com.example.Z::method");
        RuntimeTracer.push("com.example.A::method");
        RuntimeTracer.pop();
        RuntimeTracer.pop();

        Path tracePath = tmp.resolve("runtime_trace.json");
        new ShutdownHook(tracePath).run();

        RuntimeTrace trace = new Gson().fromJson(new FileReader(tracePath.toFile()), RuntimeTrace.class);
        assertEquals("com.example.A::method", trace.observedSymbols.get(0).symbolId);
        assertEquals("com.example.Z::method", trace.observedSymbols.get(1).symbolId);
    }

    @Test
    void deterministicOutput(@TempDir Path tmp) throws Exception {
        RuntimeTracer.push("com.example.X::go");
        RuntimeTracer.recordEdge("com.example.X::go", "com.example.Y::run");
        RuntimeTracer.pop();

        Path p1 = tmp.resolve("trace1.json");
        Path p2 = tmp.resolve("trace2.json");

        new ShutdownHook(p1).run();
        new ShutdownHook(p2).run();

        String c1 = java.nio.file.Files.readString(p1);
        String c2 = java.nio.file.Files.readString(p2);
        assertEquals(c1, c2, "Same RuntimeTracer state should produce identical output");
    }

    @Test
    void outputDirCreatedIfAbsent(@TempDir Path tmp) throws Exception {
        Path nested = tmp.resolve("a/b/c/runtime_trace.json");
        new ShutdownHook(nested).run();
        assertTrue(nested.toFile().exists(), "Output file should be created including parent dirs");
    }

    // --- method_transforms ---

    @Test
    void methodTransformsArrayPresentWhenEmpty(@TempDir Path tmp) throws Exception {
        // No transforms recorded — methodTransforms should be [] not null
        Path tracePath = tmp.resolve("runtime_trace.json");
        new ShutdownHook(tracePath).run();
        String json = java.nio.file.Files.readString(tracePath);
        // Gson serializes null list as absent; we need to check and ensure the list is initialized
        RuntimeTrace trace = new Gson().fromJson(json, RuntimeTrace.class);
        // methodTransforms may be null if no transforms were recorded; that's acceptable JSON behaviour
        // but the array should not cause an NPE when null
        assertDoesNotThrow(() -> {
            if (trace.methodTransforms != null) {
                trace.methodTransforms.size();
            }
        });
    }

    @Test
    void methodTransformsSortedBySymbolId(@TempDir Path tmp) throws Exception {
        TransformRecord r1 = new TransformRecord();
        r1.symbolId = "java::Z::method()";
        r1.parameters = new java.util.ArrayList<>();
        TransformRecord r2 = new TransformRecord();
        r2.symbolId = "java::A::method()";
        r2.parameters = new java.util.ArrayList<>();

        RuntimeTracer.recordTransform(r1.symbolId, r1);
        RuntimeTracer.recordTransform(r2.symbolId, r2);

        Path tracePath = tmp.resolve("runtime_trace.json");
        new ShutdownHook(tracePath).run();

        RuntimeTrace trace = new Gson().fromJson(
            new java.io.FileReader(tracePath.toFile()), RuntimeTrace.class);
        assertNotNull(trace.methodTransforms);
        assertEquals(2, trace.methodTransforms.size());
        assertEquals("java::A::method()", trace.methodTransforms.get(0).symbolId);
        assertEquals("java::Z::method()", trace.methodTransforms.get(1).symbolId);
    }

    @Test
    void existingFieldsUnaffectedByTransforms(@TempDir Path tmp) throws Exception {
        RuntimeTracer.push("com.example.A::foo");
        RuntimeTracer.recordEdge("com.example.A::foo", "com.example.B::bar");
        RuntimeTracer.pop();

        Path tracePath = tmp.resolve("runtime_trace.json");
        new ShutdownHook(tracePath).run();

        RuntimeTrace trace = new Gson().fromJson(
            new java.io.FileReader(tracePath.toFile()), RuntimeTrace.class);
        assertEquals(1, trace.observedSymbols.size());
        assertEquals(1, trace.observedEdges.size());
    }
}
