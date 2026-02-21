package com.contextslice.adapter.static_analysis;

import org.apache.maven.model.Model;
import org.apache.maven.model.io.xpp3.MavenXpp3Reader;
import org.codehaus.plexus.util.xml.pull.XmlPullParserException;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * Resolves source roots and classpath from a Maven or Gradle project.
 */
public class SourceRootResolver {

    public static class UnsupportedBuildToolException extends RuntimeException {
        public UnsupportedBuildToolException(String message) { super(message); }
    }

    /**
     * Detect build tool and resolve source roots.
     *
     * @param projectRoot absolute path to the project root directory
     */
    public SourceRoots resolve(Path projectRoot) {
        Path pomFile = projectRoot.resolve("pom.xml");
        Path gradleFile = projectRoot.resolve("build.gradle");
        Path gradleKts = projectRoot.resolve("build.gradle.kts");

        if (pomFile.toFile().exists()) {
            return resolveMaven(projectRoot, pomFile);
        } else if (gradleFile.toFile().exists() || gradleKts.toFile().exists()) {
            return resolveGradle(projectRoot);
        } else {
            throw new UnsupportedBuildToolException(
                "No pom.xml or build.gradle found in: " + projectRoot +
                ". Supported build tools: Maven, Gradle."
            );
        }
    }

    private SourceRoots resolveMaven(Path projectRoot, Path pomFile) {
        // Parse pom.xml for custom source directory
        String sourceDir = "src/main/java";
        try (FileReader reader = new FileReader(pomFile.toFile())) {
            MavenXpp3Reader pomReader = new MavenXpp3Reader();
            Model model = pomReader.read(reader);
            if (model.getBuild() != null && model.getBuild().getSourceDirectory() != null) {
                sourceDir = model.getBuild().getSourceDirectory();
            }
        } catch (IOException | XmlPullParserException e) {
            // Fall back to default
            System.err.println("[adapter] Warning: could not parse pom.xml, using default source root: " + e.getMessage());
        }

        Path absoluteSourceRoot = projectRoot.resolve(sourceDir).toAbsolutePath();
        List<String> classpathJars = collectMavenDependencyJars(projectRoot);

        return new SourceRoots(absoluteSourceRoot.toString(), classpathJars);
    }

    private SourceRoots resolveGradle(Path projectRoot) {
        // Gradle: use standard convention; no pom to parse
        Path absoluteSourceRoot = projectRoot.resolve("src/main/java").toAbsolutePath();
        List<String> classpathJars = collectGradleDependencyJars(projectRoot);
        return new SourceRoots(absoluteSourceRoot.toString(), classpathJars);
    }

    /**
     * Collect compiled JARs from the local Maven repository for classpath resolution.
     * Uses the project's target/dependency directory if populated by mvn dependency:copy-dependencies,
     * otherwise falls back to scanning ~/.m2/repository.
     */
    private List<String> collectMavenDependencyJars(Path projectRoot) {
        // Check if target/dependency directory was pre-populated
        Path depDir = projectRoot.resolve("target/dependency");
        if (depDir.toFile().exists()) {
            return collectJarsInDir(depDir);
        }
        // Fall back: scan local Maven repo (less precise but good enough for classpath)
        Path m2Repo = Paths.get(System.getProperty("user.home"), ".m2", "repository");
        if (m2Repo.toFile().exists()) {
            return collectJarsInDir(m2Repo);
        }
        return Collections.emptyList();
    }

    private List<String> collectGradleDependencyJars(Path projectRoot) {
        Path cacheDir = Paths.get(System.getProperty("user.home"), ".gradle", "caches");
        if (cacheDir.toFile().exists()) {
            return collectJarsInDir(cacheDir);
        }
        return Collections.emptyList();
    }

    private List<String> collectJarsInDir(Path dir) {
        try (Stream<Path> walk = Files.walk(dir)) {
            return walk
                .filter(p -> p.toString().endsWith(".jar"))
                .filter(p -> !p.toString().contains("-sources"))
                .filter(p -> !p.toString().contains("-tests"))
                .map(Path::toString)
                .collect(Collectors.toList());
        } catch (IOException e) {
            System.err.println("[adapter] Warning: could not scan dependency dir: " + e.getMessage());
            return Collections.emptyList();
        }
    }
}
