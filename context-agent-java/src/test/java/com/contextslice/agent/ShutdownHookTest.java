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
        RuntimeTracer.recordConfig("com.example.B::bar", "app.feature", "enabled");
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

        // configReads: 1 read
        assertEquals(1, trace.configReads.size());
        assertEquals("com.example.B::bar", trace.configReads.get(0).symbolId);
        assertEquals("app.feature", trace.configReads.get(0).configKey);
        assertEquals("enabled", trace.configReads.get(0).resolvedValue);
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
        RuntimeTracer.recordConfig("com.example.X::go", "key", "val");
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
}
