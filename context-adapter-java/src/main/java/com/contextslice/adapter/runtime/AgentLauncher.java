package com.contextslice.adapter.runtime;

import com.contextslice.adapter.ir.RuntimeTrace;
import com.google.gson.Gson;

import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.file.*;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Launches the target application JAR with the ByteBuddy agent attached,
 * optionally runs a scenario script, then waits for exit.
 *
 * Two modes:
 * - CLI mode (runScript == null): waits for the process to exit on its own (120s timeout)
 * - Server mode (runScript != null): starts the app, polls for readiness on serverPort,
 *   runs the shell run_script, sends SIGTERM, and waits for graceful shutdown.
 */
public class AgentLauncher {

    private static final int STARTUP_TIMEOUT_SECONDS = 60;
    private static final int SHUTDOWN_TIMEOUT_SECONDS = 30;
    private static final int CLI_TIMEOUT_SECONDS = 120;
    private static final Gson GSON = new Gson();

    public static class AgentLaunchException extends RuntimeException {
        public AgentLaunchException(String msg) { super(msg); }
        public AgentLaunchException(String msg, Throwable cause) { super(msg, cause); }
    }

    /**
     * Launch the app in CLI mode (app must exit on its own).
     */
    public RuntimeTrace launch(Path agentJar, Path appJar, Path outputDir, String namespace, List<String> runArgs) {
        return launch(agentJar, appJar, outputDir, namespace, runArgs, null, 8080);
    }

    /**
     * Launch the app, optionally in server mode.
     *
     * @param runScript   if non-null, use server mode: poll serverPort for readiness, run this shell command, then SIGTERM
     * @param serverPort  port to poll for HTTP readiness (ignored if runScript is null)
     */
    public RuntimeTrace launch(
            Path agentJar, Path appJar, Path outputDir,
            String namespace, List<String> runArgs,
            String runScript, int serverPort
    ) {
        try {
            Files.createDirectories(outputDir);
        } catch (IOException e) {
            throw new AgentLaunchException("Could not create output dir: " + outputDir, e);
        }

        String javaHome = System.getenv("JAVA_HOME");
        String javaExe = (javaHome != null) ? javaHome + "/bin/java" : "java";

        String agentArg = agentJar.toAbsolutePath() + "=output=" + outputDir.toAbsolutePath()
                + ",namespace=" + namespace;

        List<String> command = new ArrayList<>();
        command.add(javaExe);
        command.add("-javaagent:" + agentArg);
        command.add("-jar");
        command.add(appJar.toAbsolutePath().toString());
        if (runArgs != null) command.addAll(runArgs);

        System.err.println("[context-adapter] Launching: " + String.join(" ", command));

        ProcessBuilder pb = new ProcessBuilder(command).redirectErrorStream(true);
        if (javaHome != null) pb.environment().put("JAVA_HOME", javaHome);

        Process process;
        try {
            process = pb.start();
        } catch (IOException e) {
            throw new AgentLaunchException("Failed to start target JVM: " + e.getMessage(), e);
        }

        // Stream app output to our stderr
        Thread logThread = new Thread(() -> {
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    System.err.println("[target-app] " + line);
                }
            } catch (IOException ignored) {}
        });
        logThread.setDaemon(true);
        logThread.start();

        if (runScript != null) {
            runServerMode(process, runScript, serverPort, outputDir);
        } else {
            runCliMode(process);
        }

        Path tracePath = outputDir.resolve("runtime_trace.json");
        if (!Files.exists(tracePath)) {
            throw new AgentLaunchException(
                "runtime_trace.json not found at " + tracePath + " after JVM exit.");
        }

        try (FileReader reader = new FileReader(tracePath.toFile())) {
            RuntimeTrace trace = GSON.fromJson(reader, RuntimeTrace.class);
            if (trace == null) {
                throw new AgentLaunchException("runtime_trace.json is empty or invalid: " + tracePath);
            }
            return trace;
        } catch (IOException e) {
            throw new AgentLaunchException("Failed to read runtime_trace.json: " + e.getMessage(), e);
        }
    }

    private void runCliMode(Process process) {
        try {
            boolean finished = process.waitFor(CLI_TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (!finished) {
                process.destroyForcibly();
                throw new AgentLaunchException(
                    "Target JVM did not exit within " + CLI_TIMEOUT_SECONDS + "s.");
            }
            int exitCode = process.exitValue();
            if (exitCode != 0) {
                throw new AgentLaunchException("Target JVM exited with code " + exitCode);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            process.destroyForcibly();
            throw new AgentLaunchException("Interrupted while waiting for target JVM", e);
        }
    }

    private void runServerMode(Process process, String runScript, int serverPort, Path outputDir) {
        // 1. Wait for server readiness
        System.err.println("[context-adapter] Waiting for server on port " + serverPort + "...");
        waitForServerReady(process, serverPort);
        System.err.println("[context-adapter] Server is ready.");

        // 2. Run the scenario script
        System.err.println("[context-adapter] Running scenario script...");
        runScenarioScript(runScript);

        // 3. Send SIGTERM to trigger shutdown hook
        System.err.println("[context-adapter] Sending SIGTERM to trigger shutdown hook...");
        process.destroy();  // sends SIGTERM on Unix

        // 4. Wait for graceful shutdown
        try {
            boolean finished = process.waitFor(SHUTDOWN_TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (!finished) {
                process.destroyForcibly();
                System.err.println("[context-adapter] WARNING: App did not shut down gracefully within "
                        + SHUTDOWN_TIMEOUT_SECONDS + "s. runtime_trace.json may be missing.");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            process.destroyForcibly();
            throw new AgentLaunchException("Interrupted during server shutdown", e);
        }
    }

    private void waitForServerReady(Process process, int port) {
        long deadline = System.currentTimeMillis() + STARTUP_TIMEOUT_SECONDS * 1000L;
        while (System.currentTimeMillis() < deadline) {
            if (!process.isAlive()) {
                throw new AgentLaunchException("Target JVM exited unexpectedly during startup");
            }
            try {
                HttpURLConnection conn = (HttpURLConnection) new URL("http://localhost:" + port + "/").openConnection();
                conn.setConnectTimeout(500);
                conn.setReadTimeout(500);
                conn.connect();
                int code = conn.getResponseCode();
                if (code > 0) return;  // any HTTP response means server is up
            } catch (IOException ignored) {
                // Server not ready yet
            }
            try {
                Thread.sleep(500);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new AgentLaunchException("Interrupted while waiting for server readiness", e);
            }
        }
        process.destroyForcibly();
        throw new AgentLaunchException(
            "Server on port " + port + " did not become ready within " + STARTUP_TIMEOUT_SECONDS + "s.");
    }

    private void runScenarioScript(String script) {
        ProcessBuilder pb = new ProcessBuilder("sh", "-c", script)
                .redirectErrorStream(true);

        StringBuilder output = new StringBuilder();
        try {
            Process p = pb.start();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    output.append(line).append('\n');
                    System.err.println("[scenario] " + line);
                }
            }
            int exitCode = p.waitFor();
            if (exitCode != 0) {
                throw new AgentLaunchException(
                    "Scenario script failed (exit " + exitCode + "): " + output);
            }
        } catch (IOException e) {
            throw new AgentLaunchException("Failed to run scenario script: " + e.getMessage(), e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new AgentLaunchException("Interrupted while running scenario script", e);
        }
    }
}
