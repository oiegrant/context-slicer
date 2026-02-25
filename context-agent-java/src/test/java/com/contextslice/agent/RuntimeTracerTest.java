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

    // --- Transform recording ---

    @Test
    void recordTransformFirstInvocationStored() {
        TransformRecord r1 = new TransformRecord();
        r1.symbolId = "A";
        TransformRecord r2 = new TransformRecord();
        r2.symbolId = "A";
        RuntimeTracer.recordTransform("A", r1);
        RuntimeTracer.recordTransform("A", r2);
        assertSame(r1, RuntimeTracer.transformRecords.get("A"), "Only first record should be stored");
    }

    @Test
    void recordTransformConcurrentlyStoresExactlyOne() throws InterruptedException {
        int threadCount = 50;
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch done = new CountDownLatch(threadCount);
        ExecutorService pool = Executors.newFixedThreadPool(threadCount);

        for (int i = 0; i < threadCount; i++) {
            pool.submit(() -> {
                try {
                    start.await();
                    TransformRecord r = new TransformRecord();
                    r.symbolId = "A";
                    RuntimeTracer.recordTransform("A", r);
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

        assertEquals(1, RuntimeTracer.transformRecords.size());
    }

    @Test
    void resetClearsTransformRecords() {
        TransformRecord r = new TransformRecord();
        r.symbolId = "A";
        RuntimeTracer.recordTransform("A", r);
        assertFalse(RuntimeTracer.transformRecords.isEmpty());
        RuntimeTracer.reset();
        assertTrue(RuntimeTracer.transformRecords.isEmpty());
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
