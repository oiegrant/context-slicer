package com.contextslice.agent;

import net.bytebuddy.agent.builder.AgentBuilder;
import net.bytebuddy.asm.Advice;
import net.bytebuddy.matcher.ElementMatchers;

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
 *   output    — directory path where runtime_trace.json will be written (required)
 *   namespace — class name prefix to instrument, e.g. "com.company" (default: "com.")
 */
public class AgentBootstrap {

    public static void premain(String agentArgs, Instrumentation instrumentation) {
        AgentConfig config = parseArgs(agentArgs);
        System.err.println("[context-agent] attaching to namespace: " + config.namespace);
        System.err.println("[context-agent] output: " + config.outputPath);

        // Register shutdown hook first so it fires even if instrumentation fails
        Path tracePath = Paths.get(config.outputPath, "runtime_trace.json");
        Runtime.getRuntime().addShutdownHook(new Thread(new ShutdownHook(tracePath)));

        // Build and install ByteBuddy instrumentation
        new AgentBuilder.Default()
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

        if (agentArgs != null && !agentArgs.isBlank()) {
            for (String part : agentArgs.split(",")) {
                String[] kv = part.split("=", 2);
                if (kv.length == 2) {
                    switch (kv[0].trim()) {
                        case "output"    -> outputPath = kv[1].trim();
                        case "namespace" -> namespace  = kv[1].trim();
                    }
                }
            }
        }
        return new AgentConfig(outputPath, namespace);
    }

    record AgentConfig(String outputPath, String namespace) {}
}
