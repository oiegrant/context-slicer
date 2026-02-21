package com.contextslice.agent;

import net.bytebuddy.asm.Advice;

/**
 * ByteBuddy Advice class that intercepts Spring's Environment.getProperty(String).
 *
 * Installed on AbstractEnvironment.getProperty to capture config reads at runtime.
 * Records (currentMethod, configKey, resolvedValue) into RuntimeTracer.configReads.
 */
public class ConfigAdvice {

    @Advice.OnMethodExit
    public static void afterGetProperty(
        @Advice.Argument(0) String key,
        @Advice.Return String value
    ) {
        String currentMethod = RuntimeTracer.peek();
        RuntimeTracer.recordConfig(currentMethod, key, value);
    }
}
