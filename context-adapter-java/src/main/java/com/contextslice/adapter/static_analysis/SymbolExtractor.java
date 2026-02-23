package com.contextslice.adapter.static_analysis;

import com.contextslice.adapter.ir.IrModel.IrSymbol;
import org.eclipse.jdt.core.dom.*;

import java.util.ArrayList;
import java.util.List;
import java.util.stream.Collectors;

/**
 * ASTVisitor that extracts class, interface, and method declarations into IrSymbol list.
 */
public class SymbolExtractor extends ASTVisitor {

    private final String fileId;
    private final List<String> entryPointIds;
    private final List<IrSymbol> symbols = new ArrayList<>();

    public SymbolExtractor(String fileId, List<String> entryPointIds) {
        this.fileId = fileId;
        this.entryPointIds = entryPointIds;
    }

    public List<IrSymbol> getSymbols() { return symbols; }

    // --- Type declarations (class and interface) ---

    @Override
    public boolean visit(TypeDeclaration node) {
        IrSymbol symbol = new IrSymbol();
        ITypeBinding binding = node.resolveBinding();

        symbol.kind = node.isInterface() ? "interface" : "class";
        symbol.name = node.getName().getIdentifier();
        symbol.language = "java";
        symbol.fileId = fileId;
        symbol.lineStart = lineOf(node);
        symbol.lineEnd = lineOf(node) + approximateLength(node);
        symbol.annotations = extractAnnotationNames(node.modifiers());
        symbol.isEntryPoint = false;
        symbol.isFramework = false;
        symbol.isGenerated = false;
        symbol.container = null;

        if (binding != null) {
            symbol.id = SymbolIdGenerator.forTypeBinding(binding);
            symbol.visibility = visibilityOf(binding.getModifiers());
        } else {
            // Fallback when binding doesn't resolve
            symbol.id = "java::" + node.getName().getIdentifier();
            symbol.visibility = "package";
        }

        symbols.add(symbol);
        return true;
    }

    // --- Method declarations ---

    @Override
    public boolean visit(MethodDeclaration node) {
        IrSymbol symbol = new IrSymbol();
        IMethodBinding binding = node.resolveBinding();

        symbol.kind = node.isConstructor() ? "constructor" : "method";
        symbol.name = node.getName().getIdentifier();
        symbol.language = "java";
        symbol.fileId = fileId;

        CompilationUnit cu = (CompilationUnit) node.getRoot();
        symbol.lineStart = cu.getLineNumber(node.getStartPosition());
        symbol.lineEnd = cu.getLineNumber(node.getStartPosition() + node.getLength() - 1);
        symbol.annotations = extractAnnotationNames(node.modifiers());
        symbol.isFramework = false;
        symbol.isGenerated = false;

        if (binding != null) {
            symbol.id = SymbolIdGenerator.forMethodBinding(binding);
            symbol.visibility = visibilityOf(binding.getModifiers());
            symbol.container = SymbolIdGenerator.forTypeBinding(binding.getDeclaringClass());
        } else {
            // Best-effort fallback
            String params = ((List<?>) node.parameters()).stream()
                .map(p -> ((SingleVariableDeclaration) p).getType().toString())
                .collect(Collectors.joining(", "));
            symbol.id = "java::unknown::" + node.getName().getIdentifier() + "(" + params + ")";
            symbol.visibility = "package";
            symbol.container = null;
        }

        symbol.isEntryPoint = entryPointIds.contains(symbol.id);

        symbols.add(symbol);
        return true;
    }

    // --- Helpers ---

    private List<String> extractAnnotationNames(List<?> modifiers) {
        List<String> result = new ArrayList<>();
        for (Object mod : modifiers) {
            if (mod instanceof Annotation) {
                String name = ((Annotation) mod).getTypeName().toString();
                // Normalize: ensure it starts with @
                result.add(name.startsWith("@") ? name : "@" + name);
            }
        }
        return result;
    }

    private String visibilityOf(int modifiers) {
        if (Modifier.isPublic(modifiers))    return "public";
        if (Modifier.isProtected(modifiers)) return "protected";
        if (Modifier.isPrivate(modifiers))   return "private";
        return "package";
    }

    private int lineOf(ASTNode node) {
        CompilationUnit cu = (CompilationUnit) node.getRoot();
        return cu.getLineNumber(node.getStartPosition());
    }

    private int approximateLength(TypeDeclaration node) {
        CompilationUnit cu = (CompilationUnit) node.getRoot();
        return cu.getLineNumber(node.getStartPosition() + node.getLength() - 1) - lineOf(node);
    }
}
