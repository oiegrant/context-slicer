package com.contextslice.agent;

import net.bytebuddy.agent.builder.AgentBuilder;
import net.bytebuddy.asm.Advice;
import net.bytebuddy.matcher.ElementMatchers;
import net.bytebuddy.utility.JavaModule;

import java.lang.instrument.Instrumentation;
import java.nio.file.Path;
import java.nio.file.Paths;

import static net.bytebuddy.matcher.ElementMatchers.*;

/**
 * Java Agent entry point.
 * Attached to the target application JVM via:
 *   java -javaagent:context-agent-java.jar=output=/path/to/output,namespace=com.myapp -jar app.jar
 *
 * Agent args (key=value pairs separated by comma):
 *   output       — directory path where runtime_trace.json will be written (required)
 *   namespace    — class name prefix to instrument, e.g. "com.company" (default: "com.")
 *   transforms   — "true"/"false" — enable/disable transform capture (default: true)
 *   depth        — serialization depth limit (default: 2)
 *   max_elements — max collection elements to serialize (default: 3)
 */
public class AgentBootstrap {

    /** Shared config accessible by MethodAdvice (set during premain). */
    public static volatile AgentConfig agentConfig;

    public static void premain(String agentArgs, Instrumentation instrumentation) {
        // Allow ByteBuddy to process Java versions beyond its officially supported range.
        // Required for Java 24+ (class version 68+) with ByteBuddy < 1.17.
        System.setProperty("net.bytebuddy.experimental", "true");

        AgentConfig config = parseArgs(agentArgs);
        agentConfig = config;
        System.err.println("[context-agent] attaching to namespace: " + config.namespace);
        System.err.println("[context-agent] output: " + config.outputPath);
        System.err.println("[context-agent] transforms=" + config.transformsEnabled()
            + " depth=" + config.depthLimit() + " max_elements=" + config.maxCollectionElements());

        // Register shutdown hook first so it fires even if instrumentation fails
        Path tracePath = Paths.get(config.outputPath, "runtime_trace.json");
        Runtime.getRuntime().addShutdownHook(new Thread(new ShutdownHook(tracePath)));

        // Build and install ByteBuddy instrumentation
        new AgentBuilder.Default()
            // Log transformation errors to stderr for debugging
            .with(new AgentBuilder.Listener.Adapter() {
                @Override
                public void onError(String typeName, ClassLoader classLoader,
                                    JavaModule module, boolean loaded, Throwable throwable) {
                    System.err.println("[context-agent] TRANSFORM ERROR for " + typeName
                        + ": " + throwable);
                }
            })
            // Only instrument app classes in target namespace; exclude proxies, generated classes,
            // and the agent itself (to prevent infinite recursion in RuntimeTracer).
            .type(
                nameStartsWith(config.namespace)
                    .and(not(nameStartsWith("com.contextslice.agent")))
                    .and(not(nameContains("$$EnhancerBySpring")))
                    .and(not(nameContains("$Proxy")))
                    .and(not(nameContains("CGLIB")))
                    .and(not(nameContains("$$Lambda")))
            )
            .transform((builder, typeDescription, classLoader, module, protectionDomain) ->
                builder.method(
                    isMethod()
                        .and(not(isConstructor()))
                        .and(not(isAbstract()))
                        .and(not(isNative()))
                        .and(not(isSynthetic()))
                )
                .intercept(Advice.to(MethodAdvice.class))
            )
            .installOn(instrumentation);

        System.err.println("[context-agent] instrumentation installed");
    }

    /** Called when agent is loaded after JVM startup (dynamic attach). */
    public static void agentmain(String agentArgs, Instrumentation instrumentation) {
        premain(agentArgs, instrumentation);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    static AgentConfig parseArgs(String agentArgs) {
        String outputPath = System.getProperty("java.io.tmpdir");
        String namespace = "com.";
        boolean transformsEnabled = true;
        int depthLimit = 2;
        int maxCollectionElements = 3;

        if (agentArgs != null && !agentArgs.isBlank()) {
            for (String part : agentArgs.split(",")) {
                String[] kv = part.split("=", 2);
                if (kv.length == 2) {
                    switch (kv[0].trim()) {
                        case "output"       -> outputPath           = kv[1].trim();
                        case "namespace"    -> namespace            = kv[1].trim();
                        case "transforms"   -> transformsEnabled    = !"false".equalsIgnoreCase(kv[1].trim());
                        case "depth"        -> {
                            try { depthLimit = Integer.parseInt(kv[1].trim()); } catch (NumberFormatException ignored) {}
                        }
                        case "max_elements" -> {
                            try { maxCollectionElements = Integer.parseInt(kv[1].trim()); } catch (NumberFormatException ignored) {}
                        }
                    }
                }
            }
        }
        return new AgentConfig(outputPath, namespace, transformsEnabled, depthLimit, maxCollectionElements);
    }

    // -----------------------------------------------------------------------
    // Public static accessors for MethodAdvice (inlined bytecode must not
    // reference AgentConfig type directly — Spring Boot LaunchedClassLoader
    // cannot access package-private inner types from other packages).
    // -----------------------------------------------------------------------

    public static boolean isTransformsEnabled() {
        AgentConfig c = agentConfig;
        return c != null && c.transformsEnabled();
    }

    public static int getDepthLimit() {
        AgentConfig c = agentConfig;
        return c != null ? c.depthLimit() : 2;
    }

    public static int getMaxCollectionElements() {
        AgentConfig c = agentConfig;
        return c != null ? c.maxCollectionElements() : 3;
    }

    record AgentConfig(
        String outputPath,
        String namespace,
        boolean transformsEnabled,
        int depthLimit,
        int maxCollectionElements
    ) {}
}
