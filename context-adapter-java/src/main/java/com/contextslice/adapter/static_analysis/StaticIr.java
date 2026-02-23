package com.contextslice.adapter.static_analysis;

import com.contextslice.adapter.ir.IrModel.IrCallEdge;
import com.contextslice.adapter.ir.IrModel.IrFile;
import com.contextslice.adapter.ir.IrModel.IrSymbol;
import java.util.List;

/**
 * Aggregate result of the static analysis phase.
 */
public record StaticIr(
    List<IrFile> files,
    List<IrSymbol> symbols,
    List<IrCallEdge> callEdges
) {}
