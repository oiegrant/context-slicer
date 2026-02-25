package com.contextslice.agent;

import net.bytebuddy.asm.Advice;
import net.bytebuddy.implementation.bytecode.assign.Assigner;

import java.lang.reflect.Method;
import java.util.*;
import java.util.stream.Collectors;

/**
 * ByteBuddy Advice class for method-level call tracking and data transform capture.
 *
 * Symbol ID format: java::<fully-qualified-class-name>::<method-name>(<param-simple-types>)
 *
 * Data transform capture (Phase 13):
 *   onEnter serializes each argument to a flat Map<String,String> snapshot.
 *   The snapshots are passed to onExit via @Advice.Enter.
 *   onExit serializes exit arg state, diffs with entry state, and records the TransformRecord
 *   for the first invocation of each symbol (first-invocation-only semantics).
 *
 * Accuracy note:
 *   First-invocation-only is correct for the A→B chain (A and B have separate symbols, each
 *   gets its own record). The accuracy gap is when the same method is called N times with
 *   different data (batch/retry) — only the first call is captured.
 */
@SuppressWarnings("unchecked")
public class MethodAdvice {

    /**
     * Entry advice.
     *
     * Returns Object[] containing:
     *   [0] = String            — the symbol ID
     *   [1] = Map<String,String>[] — per-parameter entry snapshots (null if transforms disabled
     *                               or symbol already recorded)
     */
    @Advice.OnMethodEnter
    public static Object[] onEnter(
            @Advice.Origin Method method,
            @Advice.AllArguments(readOnly = true) Object[] args) {

        String typeName   = method.getDeclaringClass().getName();
        String methodName = method.getName();
        String params = Arrays.stream(method.getParameterTypes())
                .map(Class::getSimpleName)
                .collect(Collectors.joining(", "));
        String symbol = "java::" + typeName + "::" + methodName + "(" + params + ")";

        RuntimeTracer.recordEdge(RuntimeTracer.peek(), symbol);
        RuntimeTracer.push(symbol);

        // Skip serialization if transforms disabled or symbol already recorded
        if (!AgentBootstrap.isTransformsEnabled()
                || RuntimeTracer.hasTransformRecorded(symbol)) {
            return new Object[]{ symbol, null };
        }

        // Serialize entry state of each argument
        SerializerConfig sc = new SerializerConfig(AgentBootstrap.getDepthLimit(), AgentBootstrap.getMaxCollectionElements());
        Map<String, String>[] snapshots = args == null
            ? new Map[0]
            : new Map[args.length];
        if (args != null) {
            for (int i = 0; i < args.length; i++) {
                snapshots[i] = ParameterSerializer.serialize(args[i], sc);
            }
        }
        return new Object[]{ symbol, snapshots };
    }

    @Advice.OnMethodExit(onThrowable = Throwable.class)
    public static void onExit(
            @Advice.Enter Object[] enterData,
            @Advice.AllArguments(readOnly = true) Object[] exitArgs,
            @Advice.Return(typing = Assigner.Typing.DYNAMIC, readOnly = true) Object returnValue,
            @Advice.Origin Method method,
            @Advice.Thrown(readOnly = true) Throwable thrown) {

        RuntimeTracer.pop();

        if (enterData == null) return;
        String symbol = (String) enterData[0];
        if (symbol == null) return;

        Map<String, String>[] entrySnapshots = (Map<String, String>[]) enterData[1];
        // null means transforms were disabled or already recorded
        if (entrySnapshots == null) return;

        // Double-check: another thread may have stored a record since onEnter
        if (RuntimeTracer.hasTransformRecorded(symbol)) return;

        SerializerConfig sc = new SerializerConfig(AgentBootstrap.getDepthLimit(), AgentBootstrap.getMaxCollectionElements());

        Class<?>[] paramTypes  = method.getParameterTypes();
        String[]   paramNames  = buildParamNames(method);

        // Build parameter transforms
        List<TransformRecord.ParameterTransform> paramTransforms = new ArrayList<>();
        int argCount = exitArgs == null ? 0 : exitArgs.length;
        for (int i = 0; i < Math.min(entrySnapshots.length, argCount); i++) {
            TransformRecord.ParameterTransform pt = new TransformRecord.ParameterTransform();
            pt.name         = i < paramNames.length ? paramNames[i] : "arg" + i;
            pt.typeName     = i < paramTypes.length ? paramTypes[i].getSimpleName() : "Object";
            pt.entrySnapshot = entrySnapshots[i] != null ? entrySnapshots[i] : new LinkedHashMap<>();
            pt.exitSnapshot  = ParameterSerializer.serialize(exitArgs[i], sc);
            pt.computeDiff();
            paramTransforms.add(pt);
        }

        // Build return value as a compact rendered string
        String retValueStr = null;
        String retType = null;
        if (thrown == null) {
            Class<?> returnType = method.getReturnType();
            retType = returnType.getSimpleName();
            if (!returnType.equals(void.class) && returnValue != null) {
                Map<String, String> retSnapshot = ParameterSerializer.serialize(returnValue, sc);
                retValueStr = TransformRecord.renderSnapshot(retType, retSnapshot);
            }
        }

        TransformRecord record = new TransformRecord();
        record.symbolId    = symbol;
        record.parameters  = paramTransforms;
        record.returnValue = retValueStr;
        record.returnType  = retType;

        RuntimeTracer.recordTransform(symbol, record);
    }

    /**
     * Best-effort parameter name extraction.
     * Requires -parameters javac flag; otherwise falls back to "arg0", "arg1", etc.
     *
     * Package-private (not private) so that ByteBuddy-inlined advice bytecode in
     * instrumented classes can legally invoke it via INVOKESTATIC.
     */
    public static String[] buildParamNames(Method method) {
        java.lang.reflect.Parameter[] params = method.getParameters();
        String[] names = new String[params.length];
        for (int i = 0; i < params.length; i++) {
            names[i] = params[i].isNamePresent() ? params[i].getName() : "arg" + i;
        }
        return names;
    }
}
