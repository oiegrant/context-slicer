package com.contextslice.agent;

import java.util.ArrayDeque;
import java.util.Deque;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.LongAdder;

/**
 * Thread-safe, low-allocation in-memory aggregator for runtime observations.
 *
 * Uses record-based keys for edgeCounts — no string parsing/splitting required at read time.
 */
public final class RuntimeTracer {

    private RuntimeTracer() {}

    // Per-thread call stack — each entry is a symbol ID string
    static final ThreadLocal<Deque<String>> stack =
        ThreadLocal.withInitial(ArrayDeque::new);

    // Aggregated method call counts: symbolId -> count
    static final ConcurrentHashMap<String, LongAdder> methodCounts =
        new ConcurrentHashMap<>();

    // Aggregated call edge counts: EdgeKey(caller, callee) -> count
    // Record keys avoid any string-splitting ambiguity.
    static final ConcurrentHashMap<EdgeKey, LongAdder> edgeCounts =
        new ConcurrentHashMap<>();

    // First-invocation transform records: symbolId -> TransformRecord
    // putIfAbsent semantics ensure only the first invocation is stored.
    static final ConcurrentHashMap<String, TransformRecord> transformRecords =
        new ConcurrentHashMap<>();

    /** Immutable key for a directed call edge. Java records provide correct equals/hashCode. */
    record EdgeKey(String caller, String callee) {}

    // -----------------------------------------------------------------------
    // Stack operations
    // -----------------------------------------------------------------------

    public static void push(String symbolId) {
        stack.get().push(symbolId);
        methodCounts.computeIfAbsent(symbolId, k -> new LongAdder()).increment();
    }

    public static void pop() {
        Deque<String> s = stack.get();
        if (!s.isEmpty()) s.pop();
    }

    /** Returns the symbol ID at the top of the current thread's stack, or null if empty. */
    public static String peek() {
        Deque<String> s = stack.get();
        return s.isEmpty() ? null : s.peek();
    }

    // -----------------------------------------------------------------------
    // Edge recording
    // -----------------------------------------------------------------------

    /** Record a call edge. caller may be null (entry point). */
    public static void recordEdge(String caller, String callee) {
        if (caller == null || callee == null) return;
        edgeCounts.computeIfAbsent(new EdgeKey(caller, callee), k -> new LongAdder()).increment();
    }

    // -----------------------------------------------------------------------
    // Transform recording
    // -----------------------------------------------------------------------

    /**
     * Records a transform for a symbol.
     * Uses putIfAbsent so only the first invocation's transform is stored.
     */
    public static void recordTransform(String symbolId, TransformRecord record) {
        transformRecords.putIfAbsent(symbolId, record);
    }

    /**
     * Returns true if a transform has already been recorded for this symbol.
     *
     * Public accessor used by MethodAdvice (inlined into instrumented classes).
     * Direct field access to package-private {@code transformRecords} is illegal
     * from inlined bytecode running in a different package/class-loader context.
     */
    public static boolean hasTransformRecorded(String symbolId) {
        return transformRecords.containsKey(symbolId);
    }

    // -----------------------------------------------------------------------
    // Reset (for testing)
    // -----------------------------------------------------------------------

    public static void reset() {
        stack.get().clear();
        methodCounts.clear();
        edgeCounts.clear();
        transformRecords.clear();
    }
}
