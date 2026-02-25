package com.contextslice.agent;

import org.junit.jupiter.api.Test;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

class ParameterSerializerTest {

    private static final SerializerConfig DEFAULT_CONFIG = SerializerConfig.defaults(); // depth=2, max_elements=3

    // --- Null ---

    @Test
    void nullReturnsEmptyMap() {
        Map<String, String> result = ParameterSerializer.serialize(null, DEFAULT_CONFIG);
        assertTrue(result.isEmpty());
    }

    // --- Scalars ---

    @Test
    void stringScalar() {
        Map<String, String> result = ParameterSerializer.serialize("hello", DEFAULT_CONFIG);
        assertEquals("hello", result.get("value"));
    }

    @Test
    void integerScalar() {
        Map<String, String> result = ParameterSerializer.serialize(42, DEFAULT_CONFIG);
        assertEquals("42", result.get("value"));
    }

    @Test
    void doubleScalar() {
        Map<String, String> result = ParameterSerializer.serialize(3.14, DEFAULT_CONFIG);
        assertEquals("3.14", result.get("value"));
    }

    // --- POJO serialization ---

    static class OrderRequest {
        String customerId = "cust-1";
        String orderId = null;
        String status = null;
        double amount = 100.0;
    }

    @Test
    void pojoFields() {
        OrderRequest req = new OrderRequest();
        Map<String, String> result = ParameterSerializer.serialize(req, DEFAULT_CONFIG);
        assertEquals("cust-1", result.get("customerId"));
        assertEquals("null", result.get("orderId"));
        assertEquals("null", result.get("status"));
        assertEquals("100.0", result.get("amount"));
    }

    @Test
    void nullFieldValue() {
        OrderRequest req = new OrderRequest();
        Map<String, String> result = ParameterSerializer.serialize(req, DEFAULT_CONFIG);
        assertEquals("null", result.get("orderId"));
    }

    // --- Depth limit ---

    static class Outer {
        String name = "outer";
        Inner inner = new Inner();
    }
    static class Inner {
        String value = "inner-value";
        Deep deep = new Deep();
    }
    static class Deep {
        String deepValue = "very-deep";
    }

    @Test
    void depthLimit1StopsRecursion() {
        SerializerConfig shallowConfig = new SerializerConfig(1, 3);
        Outer obj = new Outer();
        Map<String, String> result = ParameterSerializer.serialize(obj, shallowConfig);
        assertEquals("outer", result.get("name"));
        // At depth limit, inner object emitted as type name
        assertEquals("<Inner>", result.get("inner"));
        assertFalse(result.containsKey("inner.value"));
    }

    @Test
    void depthLimit2ReachesOneLevel() {
        Outer obj = new Outer();
        Map<String, String> result = ParameterSerializer.serialize(obj, DEFAULT_CONFIG);
        assertEquals("outer", result.get("name"));
        assertEquals("inner-value", result.get("inner.value"));
        // deep is at depth limit (depth=2 >= limit=2)
        assertEquals("<Deep>", result.get("inner.deep"));
    }

    // --- Cycle detection ---

    static class SelfRef {
        String name = "node";
        SelfRef self;
    }

    @Test
    void circularReferenceTerminates() {
        SelfRef node = new SelfRef();
        node.self = node; // self-loop
        // Should not throw; circular field should be "<circular>"
        Map<String, String> result = assertDoesNotThrow(
            () -> ParameterSerializer.serialize(node, DEFAULT_CONFIG)
        );
        assertEquals("node", result.get("name"));
        // The self-referential field at depth 1 will see itself in visited
        assertTrue(result.containsKey("self") || result.containsKey("self.name"));
    }

    // --- Collections ---

    @Test
    void listWithMaxElements() {
        List<String> list = Arrays.asList("a", "b", "c", "d", "e");
        SerializerConfig config = new SerializerConfig(2, 2);
        Map<String, String> result = ParameterSerializer.serialize(list, config);
        assertEquals("5", result.get("length"));
        assertEquals("a", result.get("[0]"));
        assertEquals("b", result.get("[1]"));
        assertFalse(result.containsKey("[2]")); // truncated at max_elements=2
    }

    @Test
    void listPreservesLength() {
        List<String> list = Arrays.asList("x", "y", "z");
        Map<String, String> result = ParameterSerializer.serialize(list, DEFAULT_CONFIG);
        assertEquals("3", result.get("length"));
    }

    // --- All values are raw strings (no redaction) ---

    @Test
    void allValuesAreRawStrings() {
        // Verify no redaction occurs regardless of field names
        OrderRequest req = new OrderRequest();
        req.customerId = "secret-token-value";
        Map<String, String> result = ParameterSerializer.serialize(req, DEFAULT_CONFIG);
        assertEquals("secret-token-value", result.get("customerId"));
    }
}
