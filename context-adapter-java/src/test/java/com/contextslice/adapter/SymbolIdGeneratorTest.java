package com.contextslice.adapter;

import com.contextslice.adapter.static_analysis.SymbolIdGenerator;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class SymbolIdGeneratorTest {

    @Test
    void classId() {
        assertEquals(
            "java::com.example.OrderService",
            SymbolIdGenerator.forClass("com.example.OrderService")
        );
    }

    @Test
    void methodIdNoParams() {
        assertEquals(
            "java::com.example.Foo::bar()",
            SymbolIdGenerator.forMethod("com.example.Foo", "bar", new String[0])
        );
    }

    @Test
    void methodIdOneParam() {
        assertEquals(
            "java::com.example.OrderService::createOrder(OrderRequest)",
            SymbolIdGenerator.forMethod("com.example.OrderService", "createOrder", new String[]{"OrderRequest"})
        );
    }

    @Test
    void methodIdMultipleParams() {
        assertEquals(
            "java::com.example.Foo::doThing(String, int, boolean)",
            SymbolIdGenerator.forMethod("com.example.Foo", "doThing", new String[]{"String", "int", "boolean"})
        );
    }

    @Test
    void deterministicAcrossCalls() {
        String id1 = SymbolIdGenerator.forMethod("com.example.Foo", "bar", new String[]{"String"});
        String id2 = SymbolIdGenerator.forMethod("com.example.Foo", "bar", new String[]{"String"});
        assertEquals(id1, id2);
    }
}
