package com.contextslice.adapter;

import com.contextslice.adapter.ir.IrModel.IrCallEdge;
import com.contextslice.adapter.ir.IrModel.IrSymbol;
import com.contextslice.adapter.manifest.ManifestConfig;
import com.contextslice.adapter.manifest.ManifestReader;
import com.contextslice.adapter.static_analysis.StaticAnalyzer;
import com.contextslice.adapter.static_analysis.StaticIr;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Integration test: runs full static analysis on the order-service fixture.
 */
class StaticAnalyzerTest {

    private static final Path FIXTURE_ROOT =
        Paths.get(System.getProperty("user.dir"))
             .getParent()
             .resolve("test-fixtures/order-service");

    private static StaticIr ir;

    @BeforeAll
    static void runAnalysis() {
        ManifestConfig manifest = new ManifestReader().read(FIXTURE_ROOT.resolve("manifest.json"));
        ir = new StaticAnalyzer().analyze(FIXTURE_ROOT, manifest);
    }

    @Test
    void symbolCountMatchesExpected() {
        // 11 source files → at least 11 classes/interfaces; each with at least 1 method
        assertTrue(ir.symbols().size() >= 11,
            "Expected >= 11 symbols, got: " + ir.symbols().size());
    }

    @Test
    void allSymbolsHaveNonEmptyId() {
        for (IrSymbol s : ir.symbols()) {
            assertNotNull(s.id, "Symbol has null id");
            assertFalse(s.id.isEmpty(), "Symbol has empty id");
        }
    }

    @Test
    void allMethodSymbolsHaveNonNullContainer() {
        for (IrSymbol s : ir.symbols()) {
            if ("method".equals(s.kind) || "constructor".equals(s.kind)) {
                assertNotNull(s.container,
                    "Method symbol missing container: " + s.id);
            }
        }
    }

    @Test
    void stripeOrderServiceSymbolPresent() {
        Optional<IrSymbol> found = ir.symbols().stream()
            .filter(s -> s.id.contains("StripeOrderService") && "class".equals(s.kind))
            .findFirst();
        assertTrue(found.isPresent(), "StripeOrderService class symbol not found");
    }

    @Test
    void createOrderMethodPresent() {
        Optional<IrSymbol> found = ir.symbols().stream()
            .filter(s -> s.id.contains("StripeOrderService::createOrder"))
            .findFirst();
        assertTrue(found.isPresent(), "StripeOrderService::createOrder method not found");
    }

    @Test
    void orderControllerToOrderServiceCallEdgePresent() {
        boolean found = ir.callEdges().stream().anyMatch(e ->
            e.caller.contains("OrderController") && e.caller.contains("createOrder") &&
            e.callee.contains("OrderService") && e.callee.contains("createOrder")
        );
        assertTrue(found, "Call edge OrderController.createOrder -> OrderService.createOrder not found");
    }

    @Test
    void stripeOrderServiceToPaymentServiceCallEdgePresent() {
        boolean found = ir.callEdges().stream().anyMatch(e ->
            e.caller.contains("StripeOrderService") && e.caller.contains("createOrder") &&
            e.callee.contains("PaymentService") && e.callee.contains("charge")
        );
        assertTrue(found, "Call edge StripeOrderService.createOrder -> PaymentService.charge not found");
    }

    @Test
    void allCallEdgesHaveStaticTrue() {
        for (IrCallEdge e : ir.callEdges()) {
            assertTrue(e.isStatic, "Expected all static edges but found runtimeObserved=false for: " + e.caller + " -> " + e.callee);
        }
    }

    @Test
    void allCallEdgesHaveRuntimeObservedFalse() {
        for (IrCallEdge e : ir.callEdges()) {
            assertFalse(e.runtimeObserved, "Static analysis should not set runtimeObserved=true");
            assertEquals(0, e.callCount, "Static analysis should produce callCount=0");
        }
    }

    @Test
    void serviceAnnotatedClassesAreMarkedFramework() {
        Optional<IrSymbol> stripe = ir.symbols().stream()
            .filter(s -> s.id.equals("java::com.contextslice.fixture.StripeOrderService"))
            .findFirst();
        assertTrue(stripe.isPresent());
        assertTrue(stripe.get().isFramework, "StripeOrderService (@Service) should have isFramework=true");
    }

    @Test
    void pojoClassesAreNotMarkedFramework() {
        Optional<IrSymbol> orderRequest = ir.symbols().stream()
            .filter(s -> s.id.equals("java::com.contextslice.fixture.OrderRequest"))
            .findFirst();
        assertTrue(orderRequest.isPresent());
        assertFalse(orderRequest.get().isFramework, "OrderRequest POJO should have isFramework=false");
    }

    @Test
    void entryPointSymbolIsMarked() {
        Optional<IrSymbol> entryPoint = ir.symbols().stream()
            .filter(s -> s.id.contains("OrderController") && s.id.contains("createOrder"))
            .findFirst();
        assertTrue(entryPoint.isPresent());
        assertTrue(entryPoint.get().isEntryPoint, "OrderController.createOrder should be marked as entry point");
    }

    @Test
    void noNullSymbolIds() {
        Set<String> ids = ir.symbols().stream().map(s -> s.id).collect(Collectors.toSet());
        assertFalse(ids.contains(null), "No symbol should have a null ID");
    }

    @Test
    void noNullCallEdgeCaller() {
        for (IrCallEdge e : ir.callEdges()) {
            assertNotNull(e.caller, "Call edge has null caller");
            assertNotNull(e.callee, "Call edge has null callee");
        }
    }

    @Test
    void noCglibOrProxySymbols() {
        for (IrSymbol s : ir.symbols()) {
            assertFalse(s.id.contains("$$EnhancerBySpring"),
                "CGLIB proxy symbol should not appear: " + s.id);
            assertFalse(s.id.contains("$Proxy"),
                "JDK proxy symbol should not appear: " + s.id);
        }
    }
}
