package com.contextslice.adapter;

import com.contextslice.adapter.ir.IrMerger;
import com.contextslice.adapter.ir.IrModel;
import com.contextslice.adapter.ir.RuntimeTrace;
import com.contextslice.adapter.static_analysis.StaticIr;
import org.junit.jupiter.api.Test;

import java.util.Collections;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class IrMergerTest {

    private static IrModel.IrSymbol makeSymbol(String id, String kind) {
        IrModel.IrSymbol s = new IrModel.IrSymbol();
        s.id = id;
        s.kind = kind;
        s.name = id;
        return s;
    }

    private static IrModel.IrCallEdge makeEdge(String caller, String callee) {
        IrModel.IrCallEdge e = new IrModel.IrCallEdge();
        e.caller = caller;
        e.callee = callee;
        e.isStatic = true;
        e.runtimeObserved = false;
        e.callCount = 0;
        return e;
    }

    private static RuntimeTrace.ObservedEdge runtimeEdge(String caller, String callee, long count) {
        RuntimeTrace.ObservedEdge e = new RuntimeTrace.ObservedEdge();
        e.caller = caller;
        e.callee = callee;
        e.callCount = count;
        return e;
    }

    private static RuntimeTrace.ObservedSymbol runtimeSymbol(String id, long count) {
        RuntimeTrace.ObservedSymbol s = new RuntimeTrace.ObservedSymbol();
        s.symbolId = id;
        s.callCount = count;
        return s;
    }

    @Test
    void staticEdgeNotInRuntimeRemainsUnobserved() {
        StaticIr staticIr = new StaticIr(
                Collections.emptyList(),
                List.of(makeSymbol("A", "method"), makeSymbol("B", "method")),
                List.of(makeEdge("A", "B"))
        );
        RuntimeTrace rt = new RuntimeTrace();
        rt.observedEdges = Collections.emptyList();
        rt.observedSymbols = Collections.emptyList();
        rt.configReads = Collections.emptyList();

        IrModel.IrRoot merged = new IrMerger().merge(staticIr, rt, "test", List.of("A"), ".");

        IrModel.IrCallEdge edge = merged.callEdges.get(0);
        assertFalse(edge.runtimeObserved, "Edge should not be runtime-observed");
        assertEquals(0, edge.callCount);
    }

    @Test
    void staticEdgeAnnotatedWithRuntimeCount() {
        StaticIr staticIr = new StaticIr(
                Collections.emptyList(),
                List.of(makeSymbol("A", "method"), makeSymbol("B", "method")),
                List.of(makeEdge("A", "B"))
        );
        RuntimeTrace rt = new RuntimeTrace();
        rt.observedEdges = List.of(runtimeEdge("A", "B", 3));
        rt.observedSymbols = List.of(runtimeSymbol("A", 3), runtimeSymbol("B", 3));
        rt.configReads = Collections.emptyList();

        IrModel.IrRoot merged = new IrMerger().merge(staticIr, rt, "test", List.of("A"), ".");

        IrModel.IrCallEdge edge = merged.callEdges.get(0);
        assertTrue(edge.runtimeObserved, "Edge should be runtime-observed");
        assertEquals(3, edge.callCount);
    }

    @Test
    void duplicateSymbolsAreDeduplicatedFirstWins() {
        IrModel.IrSymbol s1 = makeSymbol("A", "class");
        IrModel.IrSymbol s2 = makeSymbol("A", "method");  // duplicate ID

        StaticIr staticIr = new StaticIr(
                Collections.emptyList(),
                List.of(s1, s2),
                Collections.emptyList()
        );
        RuntimeTrace rt = new RuntimeTrace();
        rt.observedEdges = Collections.emptyList();
        rt.observedSymbols = Collections.emptyList();
        rt.configReads = Collections.emptyList();

        IrModel.IrRoot merged = new IrMerger().merge(staticIr, rt, "test", List.of(), ".");

        assertEquals(1, merged.symbols.size(), "Duplicate symbol should be deduplicated");
        assertEquals("class", merged.symbols.get(0).kind, "First symbol should win");
    }

    @Test
    void configReadsFromRuntimeIncluded() {
        StaticIr staticIr = new StaticIr(
                Collections.emptyList(),
                List.of(makeSymbol("A", "method")),
                Collections.emptyList()
        );
        RuntimeTrace rt = new RuntimeTrace();
        rt.observedEdges = Collections.emptyList();
        rt.observedSymbols = Collections.emptyList();

        RuntimeTrace.ConfigRead cr = new RuntimeTrace.ConfigRead();
        cr.symbolId = "A";
        cr.configKey = "order.payment.provider";
        cr.resolvedValue = "stripe";
        rt.configReads = List.of(cr);

        IrModel.IrRoot merged = new IrMerger().merge(staticIr, rt, "test", List.of(), ".");

        assertEquals(1, merged.configReads.size());
        assertEquals("order.payment.provider", merged.configReads.get(0).configKey);
        assertEquals("stripe", merged.configReads.get(0).resolvedValue);
    }

    @Test
    void edgeWithUnknownCallerOrCalleeExcluded() {
        StaticIr staticIr = new StaticIr(
                Collections.emptyList(),
                List.of(makeSymbol("A", "method")),
                List.of(makeEdge("A", "UNKNOWN"))  // callee not in symbols
        );
        RuntimeTrace rt = new RuntimeTrace();
        rt.observedEdges = Collections.emptyList();
        rt.observedSymbols = Collections.emptyList();
        rt.configReads = Collections.emptyList();

        IrModel.IrRoot merged = new IrMerger().merge(staticIr, rt, "test", List.of(), ".");

        assertEquals(0, merged.callEdges.size(), "Edge with unknown callee should be excluded");
    }

    @Test
    void mergedRootHasCorrectMetadata() {
        StaticIr staticIr = new StaticIr(
                Collections.emptyList(), Collections.emptyList(), Collections.emptyList());
        RuntimeTrace rt = new RuntimeTrace();
        rt.observedEdges = Collections.emptyList();
        rt.observedSymbols = Collections.emptyList();
        rt.configReads = Collections.emptyList();

        IrModel.IrRoot merged = new IrMerger().merge(staticIr, rt, "my-scenario", List.of("EP"), "/repo");

        assertEquals("0.1", merged.irVersion);
        assertEquals("java", merged.language);
        assertEquals("my-scenario", merged.scenario.name);
        assertEquals(List.of("EP"), merged.scenario.entryPoints);
        assertEquals("/repo", merged.repoRoot);
    }
}
