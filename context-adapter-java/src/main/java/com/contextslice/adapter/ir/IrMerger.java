package com.contextslice.adapter.ir;

import com.contextslice.adapter.static_analysis.StaticIr;

import java.util.*;
import java.util.stream.Collectors;

/**
 * Merges static analysis output with runtime trace data to produce a unified IrRoot.
 *
 * Static IR is the source of truth for symbols and file references.
 * Runtime trace enriches call edges with observed counts.
 */
public class IrMerger {

    /**
     * Merge static IR and runtime trace into a single IrRoot.
     *
     * @param staticIr   output of StaticAnalyzer
     * @param runtime    deserialized runtime_trace.json from agent
     * @param scenarioName  scenario name from manifest
     * @param entryPoints   entry point symbol IDs from manifest
     * @param repoRoot   absolute path to the project root
     * @return merged, ready-to-serialize IrRoot
     */
    public IrModel.IrRoot merge(
            StaticIr staticIr,
            RuntimeTrace runtime,
            String scenarioName,
            List<String> entryPoints,
            String repoRoot
    ) {
        // --- Build symbol ID set (for validation) ---
        Set<String> knownSymbolIds = new LinkedHashSet<>();
        // Deduplicate: first occurrence wins
        Map<String, IrModel.IrSymbol> symbolById = new LinkedHashMap<>();
        for (IrModel.IrSymbol s : staticIr.symbols()) {
            if (!symbolById.containsKey(s.id)) {
                symbolById.put(s.id, s);
                knownSymbolIds.add(s.id);
            } else {
                System.err.println("[context-adapter] WARNING: duplicate symbol ID ignored: " + s.id);
            }
        }

        // Mark entry points
        if (entryPoints != null) {
            for (String ep : entryPoints) {
                IrModel.IrSymbol sym = symbolById.get(ep);
                if (sym != null) {
                    sym.isEntryPoint = true;
                }
            }
        }

        // --- Build runtime lookup structures ---
        // observed edge: "caller -> callee" -> callCount
        Map<String, Long> runtimeEdgeCounts = new HashMap<>();
        for (RuntimeTrace.ObservedEdge edge : runtime.getObservedEdges()) {
            if (edge.caller != null && edge.callee != null) {
                runtimeEdgeCounts.put(edge.caller + "\u2192" + edge.callee, edge.callCount);
            }
        }

        // runtime-observed symbol IDs
        Set<String> runtimeObservedSymbols = runtime.getObservedSymbols().stream()
                .map(s -> s.symbolId)
                .filter(Objects::nonNull)
                .collect(Collectors.toSet());

        // Log runtime symbols not in static IR (for diagnostics)
        for (String id : runtimeObservedSymbols) {
            if (!knownSymbolIds.contains(id)) {
                System.err.println("[context-adapter] WARNING: runtime symbol not in static IR (ignored): " + id);
            }
        }

        // --- Annotate call edges with runtime data ---
        List<IrModel.IrCallEdge> mergedEdges = new ArrayList<>();
        for (IrModel.IrCallEdge edge : staticIr.callEdges()) {
            // Filter edges whose caller or callee are not known symbols
            if (!knownSymbolIds.contains(edge.caller) || !knownSymbolIds.contains(edge.callee)) {
                continue;
            }
            String key = edge.caller + "\u2192" + edge.callee;
            Long runtimeCount = runtimeEdgeCounts.get(key);
            if (runtimeCount != null) {
                edge.runtimeObserved = true;
                edge.callCount = runtimeCount;
            }
            mergedEdges.add(edge);
        }

        // Build set of already-merged edge keys to avoid duplicates
        Set<String> mergedEdgeKeys = new HashSet<>();
        for (IrModel.IrCallEdge e : mergedEdges) {
            mergedEdgeKeys.add(e.caller + "\u2192" + e.callee);
        }

        // Add runtime-only edges where both caller and callee are in the known symbol set.
        // These represent concrete implementation dispatches observed at runtime
        // (e.g., interface call in static IR, but runtime saw the concrete class).
        for (RuntimeTrace.ObservedEdge re : runtime.getObservedEdges()) {
            if (re.caller == null || re.callee == null) continue;
            String key = re.caller + "\u2192" + re.callee;
            if (mergedEdgeKeys.contains(key)) continue;  // already included from static

            if (!knownSymbolIds.contains(re.caller) || !knownSymbolIds.contains(re.callee)) {
                System.err.println("[context-adapter] WARNING: runtime edge references unknown symbol (excluded): "
                        + re.caller + " -> " + re.callee);
                continue;
            }

            // Include as a runtime-only edge
            IrModel.IrCallEdge runtimeOnlyEdge = new IrModel.IrCallEdge();
            runtimeOnlyEdge.caller = re.caller;
            runtimeOnlyEdge.callee = re.callee;
            runtimeOnlyEdge.isStatic = false;
            runtimeOnlyEdge.runtimeObserved = true;
            runtimeOnlyEdge.callCount = re.callCount;
            mergedEdges.add(runtimeOnlyEdge);
            mergedEdgeKeys.add(key);
        }

        // --- Build config reads from runtime trace ---
        List<IrModel.IrConfigRead> configReads = new ArrayList<>();
        for (RuntimeTrace.ConfigRead cr : runtime.getConfigReads()) {
            if (cr.symbolId == null || cr.configKey == null) continue;
            IrModel.IrConfigRead irCr = new IrModel.IrConfigRead();
            irCr.symbolId = cr.symbolId;
            irCr.configKey = cr.configKey;
            irCr.resolvedValue = cr.resolvedValue;
            configReads.add(irCr);
        }

        // --- Build runtime block ---
        IrModel.IrRuntime runtimeBlock = new IrModel.IrRuntime();
        runtimeBlock.observedSymbols = runtime.getObservedSymbols().stream()
                .filter(s -> knownSymbolIds.contains(s.symbolId))
                .map(s -> {
                    IrModel.IrObservedSymbol obs = new IrModel.IrObservedSymbol();
                    obs.symbolId = s.symbolId;
                    obs.callCount = s.callCount;
                    return obs;
                })
                .collect(Collectors.toList());
        runtimeBlock.observedEdges = runtime.getObservedEdges().stream()
                .filter(e -> e.caller != null && e.callee != null)
                .map(e -> {
                    IrModel.IrObservedEdge obs = new IrModel.IrObservedEdge();
                    obs.caller = e.caller;
                    obs.callee = e.callee;
                    obs.callCount = e.callCount;
                    return obs;
                })
                .collect(Collectors.toList());

        // --- Build scenario ---
        IrModel.IrScenario scenario = new IrModel.IrScenario();
        scenario.name = scenarioName;
        scenario.entryPoints = entryPoints != null ? entryPoints : Collections.emptyList();

        // --- Assemble IrRoot ---
        IrModel.IrRoot root = new IrModel.IrRoot();
        root.irVersion = "0.1";
        root.language = "java";
        root.repoRoot = repoRoot;
        root.adapterVersion = "0.1.0";
        root.scenario = scenario;
        root.files = staticIr.files();
        root.symbols = new ArrayList<>(symbolById.values());
        root.callEdges = mergedEdges;
        root.configReads = configReads;
        root.runtime = runtimeBlock;

        return root;
    }
}
