package com.contextslice.adapter.build;

import java.io.*;
import java.nio.file.*;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Collectors;

/**
 * Builds the target project (Maven or Gradle) and returns the path to the produced JAR.
 */
public class BuildRunner {

    public static class BuildException extends RuntimeException {
        public BuildException(String msg) { super(msg); }
        public BuildException(String msg, Throwable cause) { super(msg, cause); }
    }

    /**
     * Builds the project at {@code projectRoot}.
     *
     * @return absolute path to the produced fat JAR
     * @throws BuildException if the build fails or no JAR is found
     */
    public Path build(Path projectRoot) {
        if (!Files.isDirectory(projectRoot)) {
            throw new BuildException("Project root does not exist or is not a directory: " + projectRoot);
        }

        boolean isMaven = Files.exists(projectRoot.resolve("pom.xml"));
        boolean isGradle = Files.exists(projectRoot.resolve("build.gradle"))
                        || Files.exists(projectRoot.resolve("build.gradle.kts"));

        if (!isMaven && !isGradle) {
            throw new BuildException("No pom.xml or build.gradle found in: " + projectRoot);
        }

        List<String> command;
        Path targetDir;

        if (isMaven) {
            command = List.of("mvn", "package", "-DskipTests", "-q");
            targetDir = projectRoot.resolve("target");
        } else {
            command = List.of("./gradlew", "assemble", "-x", "test", "-q");
            targetDir = projectRoot.resolve("build").resolve("libs");
        }

        runCommand(command, projectRoot);
        return findJar(targetDir);
    }

    private void runCommand(List<String> command, Path workDir) {
        ProcessBuilder pb = new ProcessBuilder(command)
                .directory(workDir.toFile())
                .redirectErrorStream(true);

        // Pass through JAVA_HOME if set
        String javaHome = System.getenv("JAVA_HOME");
        if (javaHome != null) {
            pb.environment().put("JAVA_HOME", javaHome);
            pb.environment().put("PATH", javaHome + "/bin:" + System.getenv("PATH"));
        }

        StringBuilder output = new StringBuilder();
        try {
            Process process = pb.start();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    output.append(line).append('\n');
                    System.err.println("[context-adapter] BUILD: " + line);
                }
            }
            int exitCode = process.waitFor();
            if (exitCode != 0) {
                throw new BuildException("Build failed (exit " + exitCode + "):\n" + output);
            }
        } catch (IOException e) {
            throw new BuildException("Failed to spawn build process: " + e.getMessage(), e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new BuildException("Build interrupted", e);
        }
    }

    private Path findJar(Path targetDir) {
        if (!Files.isDirectory(targetDir)) {
            throw new BuildException("Target directory not found after build: " + targetDir);
        }

        try {
            List<Path> jars = Files.list(targetDir)
                    .filter(p -> {
                        String name = p.getFileName().toString();
                        return name.endsWith(".jar")
                            && !name.endsWith("-sources.jar")
                            && !name.endsWith("-tests.jar")
                            && !name.endsWith("-test.jar")
                            && !name.startsWith("original-");
                    })
                    .sorted(Comparator.comparingLong(p -> {
                        try { return -Files.size(p); } catch (IOException e) { return 0L; }
                    }))
                    .collect(Collectors.toList());

            if (jars.isEmpty()) {
                throw new BuildException("No JAR found in: " + targetDir);
            }

            return jars.get(0).toAbsolutePath();
        } catch (IOException e) {
            throw new BuildException("Error listing target directory: " + e.getMessage(), e);
        }
    }
}
