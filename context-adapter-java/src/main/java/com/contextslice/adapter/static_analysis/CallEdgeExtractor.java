package com.contextslice.adapter.static_analysis;

import com.contextslice.adapter.ir.IrModel.IrCallEdge;
import org.eclipse.jdt.core.dom.*;

import java.util.ArrayList;
import java.util.List;

/**
 * ASTVisitor that extracts method invocations as static call edges.
 * All edges produced have static=true, runtimeObserved=false, callCount=0.
 */
public class CallEdgeExtractor extends ASTVisitor {

    private final List<IrCallEdge> edges = new ArrayList<>();
    private String currentMethodId = null;

    public List<IrCallEdge> getEdges() { return edges; }

    @Override
    public boolean visit(MethodDeclaration node) {
        IMethodBinding binding = node.resolveBinding();
        if (binding != null) {
            currentMethodId = SymbolIdGenerator.forMethodBinding(binding);
        } else {
            currentMethodId = null;
        }
        return true;
    }

    @Override
    public void endVisit(MethodDeclaration node) {
        currentMethodId = null;
    }

    @Override
    public boolean visit(MethodInvocation node) {
        if (currentMethodId == null) return true;
        IMethodBinding binding = node.resolveMethodBinding();
        if (binding == null) return true; // unresolvable — skip with no error

        String calleeId = SymbolIdGenerator.forMethodBinding(binding);
        recordEdge(currentMethodId, calleeId);
        return true;
    }

    @Override
    public boolean visit(ClassInstanceCreation node) {
        if (currentMethodId == null) return true;
        IMethodBinding binding = node.resolveConstructorBinding();
        if (binding == null) return true;

        // Callee for a constructor call is the class type, not the constructor method itself
        String calleeId = SymbolIdGenerator.forTypeBinding(binding.getDeclaringClass());
        recordEdge(currentMethodId, calleeId);
        return true;
    }

    @Override
    public boolean visit(SuperMethodInvocation node) {
        if (currentMethodId == null) return true;
        IMethodBinding binding = node.resolveMethodBinding();
        if (binding == null) return true;

        String calleeId = SymbolIdGenerator.forMethodBinding(binding);
        recordEdge(currentMethodId, calleeId);
        return true;
    }

    private void recordEdge(String callerId, String calleeId) {
        // Deduplicate within this extraction pass
        for (IrCallEdge existing : edges) {
            if (existing.caller.equals(callerId) && existing.callee.equals(calleeId)) {
                return;
            }
        }
        IrCallEdge edge = new IrCallEdge();
        edge.caller = callerId;
        edge.callee = calleeId;
        edge.isStatic = true;
        edge.runtimeObserved = false;
        edge.callCount = 0;
        edges.add(edge);
    }
}
