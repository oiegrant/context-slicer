package com.contextslice.adapter;

import com.contextslice.adapter.static_analysis.SourceRootResolver;
import com.contextslice.adapter.static_analysis.SourceRoots;
import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.*;

class SourceRootResolverTest {

    private static final Path FIXTURE_ROOT =
        Paths.get(System.getProperty("user.dir"))
             .getParent()
             .resolve("test-fixtures/order-service");

    private final SourceRootResolver resolver = new SourceRootResolver();

    @Test
    void mavenProjectResolvesCorrectSourceRoot() {
        SourceRoots roots = resolver.resolve(FIXTURE_ROOT);
        assertTrue(roots.sourceRoot().endsWith("src/main/java"),
            "Expected source root to end with src/main/java but got: " + roots.sourceRoot());
        assertTrue(Path.of(roots.sourceRoot()).toFile().exists(),
            "Source root directory must exist: " + roots.sourceRoot());
    }

    @Test
    void mavenProjectReturnsNonEmptyClasspath() {
        SourceRoots roots = resolver.resolve(FIXTURE_ROOT);
        assertFalse(roots.classpathJars().isEmpty(),
            "Expected at least some classpath JARs from ~/.m2");
    }

    @Test
    void noBuildFileThrows() {
        Path emptyDir = Paths.get(System.getProperty("java.io.tmpdir"), "cs-test-empty-" + System.currentTimeMillis());
        emptyDir.toFile().mkdirs();
        assertThrows(SourceRootResolver.UnsupportedBuildToolException.class,
            () -> resolver.resolve(emptyDir));
    }
}
