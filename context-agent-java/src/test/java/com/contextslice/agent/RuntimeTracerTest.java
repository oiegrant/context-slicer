package com.contextslice.agent;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.junit.jupiter.api.Assertions.*;

class RuntimeTracerTest {

    @BeforeEach
    void reset() {
        RuntimeTracer.reset();
    }

    // --- Stack operations ---

    @Test
    void pushPeekPop() {
        RuntimeTracer.push("A");
        RuntimeTracer.push("B");
        assertEquals("B", RuntimeTracer.peek());
        RuntimeTracer.pop();
        assertEquals("A", RuntimeTracer.peek());
        RuntimeTracer.pop();
        assertNull(RuntimeTracer.peek());
    }

    @Test
    void peekOnEmptyStackReturnsNull() {
        assertNull(RuntimeTracer.peek());
    }

    @Test
    void popOnEmptyStackDoesNotThrow() {
        assertDoesNotThrow(RuntimeTracer::pop);
    }

    @Test
    void pushIncrementsMethodCount() {
        RuntimeTracer.push("com.example.Foo::bar");
        assertEquals(1L, RuntimeTracer.methodCounts.get("com.example.Foo::bar").sum());
        RuntimeTracer.push("com.example.Foo::bar");
        assertEquals(2L, RuntimeTracer.methodCounts.get("com.example.Foo::bar").sum());
    }

    // --- Edge recording ---

    @Test
    void recordEdgeIncrementsCount() {
        RuntimeTracer.recordEdge("A", "B");
        assertEquals(1L, RuntimeTracer.edgeCounts.get(new RuntimeTracer.EdgeKey("A", "B")).sum());
        RuntimeTracer.recordEdge("A", "B");
        assertEquals(2L, RuntimeTracer.edgeCounts.get(new RuntimeTracer.EdgeKey("A", "B")).sum());
    }

    @Test
    void recordEdgeWithNullCallerIsIgnored() {
        assertDoesNotThrow(() -> RuntimeTracer.recordEdge(null, "B"));
        assertTrue(RuntimeTracer.edgeCounts.isEmpty());
    }

    // --- Config recording ---

    @Test
    void recordConfigStoresValue() {
        RuntimeTracer.recordConfig("A", "order.provider", "stripe");
        assertEquals("stripe", RuntimeTracer.configReads.get("A").get("order.provider"));
    }

    @Test
    void recordConfigWithNullResolvedValueStoresUnset() {
        RuntimeTracer.recordConfig("A", "some.key", null);
        assertEquals("<unset>", RuntimeTracer.configReads.get("A").get("some.key"));
    }

    @Test
    void recordConfigWithNullSymbolIdIsIgnored() {
        assertDoesNotThrow(() -> RuntimeTracer.recordConfig(null, "key", "val"));
        assertTrue(RuntimeTracer.configReads.isEmpty());
    }

    // --- Thread isolation ---

    @Test
    void threadLocalStacksAreIsolated() throws InterruptedException {
        RuntimeTracer.push("main-thread-value");

        AtomicBoolean otherThreadSeesValue = new AtomicBoolean(false);
        Thread other = new Thread(() -> {
            otherThreadSeesValue.set(RuntimeTracer.peek() != null);
        });
        other.start();
        other.join();

        assertFalse(otherThreadSeesValue.get(), "Thread should not see main thread's stack");
    }

    // --- Concurrency ---

    @Test
    void concurrentEdgeRecordingIsCorrect() throws InterruptedException {
        int threadCount = 50;
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch done = new CountDownLatch(threadCount);
        ExecutorService pool = Executors.newFixedThreadPool(threadCount);

        for (int i = 0; i < threadCount; i++) {
            pool.submit(() -> {
                try {
                    start.await();
                    RuntimeTracer.recordEdge("A", "B");
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } finally {
                    done.countDown();
                }
            });
        }

        start.countDown();
        done.await(5, TimeUnit.SECONDS);
        pool.shutdown();

        assertEquals(threadCount, RuntimeTracer.edgeCounts.get(new RuntimeTracer.EdgeKey("A", "B")).sum());
    }
}
