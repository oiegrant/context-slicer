package com.contextslice.adapter;

import com.contextslice.adapter.build.BuildRunner;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.*;

import static org.junit.jupiter.api.Assertions.*;

class BuildRunnerTest {

    static final Path ORDER_SERVICE = Paths.get(
            System.getProperty("user.dir"),
            "..", "test-fixtures", "order-service").normalize();

    @Test
    void buildOrderServiceProducesJar() {
        BuildRunner runner = new BuildRunner();
        Path jar = runner.build(ORDER_SERVICE);
        assertNotNull(jar);
        assertTrue(jar.toString().endsWith(".jar"), "Expected .jar: " + jar);
        assertTrue(Files.exists(jar), "JAR must exist on disk: " + jar);
    }

    @Test
    void nonExistentProjectRootThrowsBuildException(@TempDir Path tmp) {
        Path missing = tmp.resolve("does-not-exist");
        BuildRunner runner = new BuildRunner();
        assertThrows(BuildRunner.BuildException.class, () -> runner.build(missing));
    }

    @Test
    void directoryWithNoBuildFileThrowsBuildException(@TempDir Path tmp) {
        BuildRunner runner = new BuildRunner();
        assertThrows(BuildRunner.BuildException.class, () -> runner.build(tmp));
    }

    @Test
    void producedJarIsNotSourcesJar() {
        BuildRunner runner = new BuildRunner();
        Path jar = runner.build(ORDER_SERVICE);
        String name = jar.getFileName().toString();
        assertFalse(name.contains("-sources"), "Should not return sources JAR: " + name);
        assertFalse(name.startsWith("original-"), "Should not return original- JAR: " + name);
    }
}
