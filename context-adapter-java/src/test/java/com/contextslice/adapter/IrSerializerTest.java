package com.contextslice.adapter;

import com.contextslice.adapter.ir.IrModel;
import com.contextslice.adapter.ir.IrSerializer;
import com.google.gson.Gson;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.FileReader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class IrSerializerTest {

    private IrModel.IrRoot makeRoot() {
        IrModel.IrSymbol s1 = new IrModel.IrSymbol();
        s1.id = "com.example.Z";
        s1.kind = "class";
        s1.name = "Z";

        IrModel.IrSymbol s2 = new IrModel.IrSymbol();
        s2.id = "com.example.A";
        s2.kind = "class";
        s2.name = "A";

        IrModel.IrCallEdge edge1 = new IrModel.IrCallEdge();
        edge1.caller = "com.example.Z";
        edge1.callee = "com.example.A";

        IrModel.IrCallEdge edge2 = new IrModel.IrCallEdge();
        edge2.caller = "com.example.A";
        edge2.callee = "com.example.Z";

        IrModel.IrRoot root = new IrModel.IrRoot();
        root.irVersion = "0.1";
        root.language = "java";
        root.adapterVersion = "0.1.0";
        root.scenario = new IrModel.IrScenario();
        root.scenario.name = "test";
        root.scenario.entryPoints = List.of();
        root.symbols = List.of(s1, s2);  // Z before A intentionally
        root.callEdges = List.of(edge1, edge2);  // Z→A before A→Z intentionally
        root.configReads = List.of();
        root.files = List.of();
        root.runtime = new IrModel.IrRuntime();
        root.runtime.observedSymbols = List.of();
        root.runtime.observedEdges = List.of();
        return root;
    }

    @Test
    void symbolsSortedByIdInOutput(@TempDir Path tmp) throws Exception {
        IrSerializer serializer = new IrSerializer();
        serializer.write(makeRoot(), tmp, "test");

        Path irPath = tmp.resolve("static_ir.json");
        assertTrue(Files.exists(irPath));

        IrModel.IrRoot parsed = new Gson().fromJson(new FileReader(irPath.toFile()), IrModel.IrRoot.class);
        assertEquals("com.example.A", parsed.symbols.get(0).id, "A should come before Z");
        assertEquals("com.example.Z", parsed.symbols.get(1).id);
    }

    @Test
    void callEdgesSortedByCallerThenCallee(@TempDir Path tmp) throws Exception {
        IrSerializer serializer = new IrSerializer();
        serializer.write(makeRoot(), tmp, "test");

        IrModel.IrRoot parsed = new Gson().fromJson(
                new FileReader(tmp.resolve("static_ir.json").toFile()), IrModel.IrRoot.class);

        // A→Z should come before Z→A
        assertEquals("com.example.A", parsed.callEdges.get(0).caller);
        assertEquals("com.example.Z", parsed.callEdges.get(1).caller);
    }

    @Test
    void deterministicOutput(@TempDir Path tmp) throws Exception {
        IrSerializer serializer = new IrSerializer();
        serializer.write(makeRoot(), tmp, "test");
        String content1 = Files.readString(tmp.resolve("static_ir.json"));

        serializer.write(makeRoot(), tmp, "test");
        String content2 = Files.readString(tmp.resolve("static_ir.json"));

        assertEquals(content1, content2, "Identical input should produce identical output");
    }

    @Test
    void metadataJsonWrittenWithExpectedFields(@TempDir Path tmp) throws Exception {
        IrSerializer serializer = new IrSerializer();
        serializer.write(makeRoot(), tmp, "my-scenario");

        Path metaPath = tmp.resolve("metadata.json");
        assertTrue(Files.exists(metaPath), "metadata.json must be created");

        String metaJson = Files.readString(metaPath);
        assertTrue(metaJson.contains("\"my-scenario\""), "scenarioName must be present");
        assertTrue(metaJson.contains("\"java\""), "language must be present");
        assertTrue(metaJson.contains("adapterVersion"), "adapterVersion must be present");
        assertTrue(metaJson.contains("timestamp"), "timestamp must be present");
    }

    @Test
    void outputDirCreatedIfAbsent(@TempDir Path tmp) throws Exception {
        Path nested = tmp.resolve("a/b/c");
        IrSerializer serializer = new IrSerializer();
        serializer.write(makeRoot(), nested, "test");
        assertTrue(Files.exists(nested.resolve("static_ir.json")));
    }

    @Test
    void outputIsValidJsonParseable(@TempDir Path tmp) throws Exception {
        IrSerializer serializer = new IrSerializer();
        serializer.write(makeRoot(), tmp, "test");

        String content = Files.readString(tmp.resolve("static_ir.json"));
        // Gson should parse it back without throwing
        IrModel.IrRoot parsed = new Gson().fromJson(content, IrModel.IrRoot.class);
        assertNotNull(parsed);
        assertEquals("0.1", parsed.irVersion);
    }
}
