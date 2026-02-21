package com.contextslice.adapter.static_analysis;

import com.contextslice.adapter.ir.IrModel.IrSymbol;
import java.util.List;
import java.util.Set;

/**
 * Post-processes extracted symbols to set isFramework=true for Spring stereotype classes
 * and for any class in the org.springframework.* package.
 */
public class AnnotationProcessor {

    private static final Set<String> FRAMEWORK_ANNOTATIONS = Set.of(
        "@Component", "@Service", "@Repository", "@Controller", "@RestController",
        "@Configuration", "@Bean", "@Autowired", "@SpringBootApplication",
        "@EnableAutoConfiguration", "@ConditionalOnProperty", "@Profile",
        "@EventListener", "@Scheduled", "@Async"
    );

    /**
     * Mutates each IrSymbol in the list: sets isFramework=true where applicable.
     */
    public void process(List<IrSymbol> symbols) {
        for (IrSymbol symbol : symbols) {
            if (isFrameworkByAnnotation(symbol) || isFrameworkByPackage(symbol)) {
                symbol.isFramework = true;
            }
        }
    }

    private boolean isFrameworkByAnnotation(IrSymbol symbol) {
        if (symbol.annotations == null) return false;
        for (String annotation : symbol.annotations) {
            if (FRAMEWORK_ANNOTATIONS.contains(annotation)) return true;
        }
        return false;
    }

    private boolean isFrameworkByPackage(IrSymbol symbol) {
        // ID format: java::<fqn> or java::<fqn>::<method>
        if (symbol.id == null) return false;
        String withoutPrefix = symbol.id.startsWith("java::") ? symbol.id.substring(6) : symbol.id;
        // Extract class part (before ::method if present)
        int methodSep = withoutPrefix.indexOf("::");
        String classPart = methodSep >= 0 ? withoutPrefix.substring(0, methodSep) : withoutPrefix;
        return classPart.startsWith("org.springframework.") ||
               classPart.startsWith("com.sun.") ||
               classPart.startsWith("java.") ||
               classPart.startsWith("javax.");
    }
}
