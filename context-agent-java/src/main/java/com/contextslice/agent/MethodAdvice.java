package com.contextslice.agent;

import net.bytebuddy.asm.Advice;

import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.stream.Collectors;

/**
 * ByteBuddy Advice class for method-level call tracking.
 *
 * Produces symbol IDs in the format:
 *   java::<fully-qualified-class-name>::<method-name>(<param-simple-types>)
 *
 * This matches the static analysis symbol ID convention from SymbolIdGenerator.
 */
public class MethodAdvice {

    @Advice.OnMethodEnter
    public static void onEnter(@Advice.Origin Method method) {
        String typeName = method.getDeclaringClass().getName();
        String methodName = method.getName();
        String params = Arrays.stream(method.getParameterTypes())
                .map(Class::getSimpleName)
                .collect(Collectors.joining(", "));
        String symbol = "java::" + typeName + "::" + methodName + "(" + params + ")";
        String caller = RuntimeTracer.peek();
        RuntimeTracer.recordEdge(caller, symbol);
        RuntimeTracer.push(symbol);
    }

    @Advice.OnMethodExit(onThrowable = Throwable.class)
    public static void onExit() {
        RuntimeTracer.pop();
    }
}
