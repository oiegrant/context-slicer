package com.contextslice.adapter.static_analysis;

import org.eclipse.jdt.core.dom.IMethodBinding;
import org.eclipse.jdt.core.dom.ITypeBinding;

import java.util.Arrays;
import java.util.stream.Collectors;

/**
 * Generates deterministic, stable symbol IDs following the convention:
 *   java::<fully-qualified-class-name>                             (class/interface)
 *   java::<fully-qualified-class-name>::<method>(<param-types>)   (method/constructor)
 */
public class SymbolIdGenerator {

    public static String forClass(String fullyQualifiedName) {
        return "java::" + fullyQualifiedName;
    }

    public static String forMethod(String fullyQualifiedClassName, String methodName, String[] paramSimpleTypes) {
        String params = Arrays.stream(paramSimpleTypes)
            .collect(Collectors.joining(", "));
        return "java::" + fullyQualifiedClassName + "::" + methodName + "(" + params + ")";
    }

    /**
     * Produce ID from a resolved ITypeBinding.
     */
    public static String forTypeBinding(ITypeBinding binding) {
        return "java::" + binding.getQualifiedName();
    }

    /**
     * Produce ID from a resolved IMethodBinding.
     */
    public static String forMethodBinding(IMethodBinding binding) {
        String className = binding.getDeclaringClass().getQualifiedName();
        String methodName = binding.isConstructor() ? "<init>" : binding.getName();
        String params = Arrays.stream(binding.getParameterTypes())
            .map(ITypeBinding::getName)  // simple name, not fully-qualified
            .collect(Collectors.joining(", "));
        return "java::" + className + "::" + methodName + "(" + params + ")";
    }
}
