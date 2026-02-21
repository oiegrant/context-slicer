package com.contextslice.adapter.manifest;

import com.google.gson.Gson;
import java.io.FileNotFoundException;
import java.io.FileReader;
import java.io.IOException;
import java.nio.file.Path;

public class ManifestReader {

    private static final Gson GSON = new Gson();

    /**
     * Reads and deserializes manifest.json from the given path.
     *
     * @throws ManifestReadException if the file is missing or malformed
     */
    public ManifestConfig read(Path manifestPath) {
        if (!manifestPath.toFile().exists()) {
            throw new ManifestReadException("Manifest file not found: " + manifestPath);
        }
        try (FileReader reader = new FileReader(manifestPath.toFile())) {
            ManifestConfig config = GSON.fromJson(reader, ManifestConfig.class);
            if (config == null) {
                throw new ManifestReadException("Manifest file is empty or invalid JSON: " + manifestPath);
            }
            return config;
        } catch (FileNotFoundException e) {
            throw new ManifestReadException("Manifest file not found: " + manifestPath, e);
        } catch (IOException e) {
            throw new ManifestReadException("Failed to read manifest: " + manifestPath + " — " + e.getMessage(), e);
        }
    }

    public static class ManifestReadException extends RuntimeException {
        public ManifestReadException(String message) { super(message); }
        public ManifestReadException(String message, Throwable cause) { super(message, cause); }
    }
}
