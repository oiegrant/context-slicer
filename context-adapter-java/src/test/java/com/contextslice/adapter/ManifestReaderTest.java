package com.contextslice.adapter;

import com.contextslice.adapter.manifest.ManifestConfig;
import com.contextslice.adapter.manifest.ManifestReader;
import com.google.gson.Gson;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class ManifestReaderTest {

    private final ManifestReader reader = new ManifestReader();
    private final Gson gson = new Gson();

    @Test
    void roundTrip(@TempDir Path tmp) throws IOException {
        String json = """
            {
              "scenario_name": "submit-order",
              "entry_points": ["java::com.example.OrderController::createOrder(OrderRequest)"],
              "run_args": ["--tenant=abc"],
              "config_files": ["application.yml"],
              "output_dir": "/tmp/out"
            }
            """;
        Path manifest = tmp.resolve("manifest.json");
        Files.writeString(manifest, json);

        ManifestConfig config = reader.read(manifest);
        assertEquals("submit-order", config.getScenarioName());
        assertEquals(List.of("java::com.example.OrderController::createOrder(OrderRequest)"), config.getEntryPoints());
        assertEquals(List.of("--tenant=abc"), config.getRunArgs());
        assertEquals(List.of("application.yml"), config.getConfigFiles());
        assertEquals("/tmp/out", config.getOutputDir());
    }

    @Test
    void missingRunArgsFieldReturnsEmptyList(@TempDir Path tmp) throws IOException {
        String json = """
            {
              "scenario_name": "test",
              "entry_points": [],
              "config_files": [],
              "output_dir": "/tmp"
            }
            """;
        Path manifest = tmp.resolve("manifest.json");
        Files.writeString(manifest, json);

        ManifestConfig config = reader.read(manifest);
        assertNotNull(config.getRunArgs());
        assertTrue(config.getRunArgs().isEmpty());
    }

    @Test
    void fileNotFoundThrowsManifestReadException() {
        Path missing = Path.of("/tmp/does-not-exist-manifest.json");
        assertThrows(ManifestReader.ManifestReadException.class, () -> reader.read(missing));
    }

    @Test
    void emptyFileThrowsManifestReadException(@TempDir Path tmp) throws IOException {
        Path empty = tmp.resolve("empty.json");
        Files.writeString(empty, "");
        assertThrows(ManifestReader.ManifestReadException.class, () -> reader.read(empty));
    }
}
