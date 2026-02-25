package com.contextslice.agent;

import com.google.gson.Gson;
import org.junit.jupiter.api.Test;

import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

class TransformRecordTest {

    private TransformRecord.ParameterTransform makeParamTransform(
            Map<String, String> entry,
            Map<String, String> exit) {
        TransformRecord.ParameterTransform pt = new TransformRecord.ParameterTransform();
        pt.name = "request";
        pt.typeName = "OrderRequest";
        pt.entrySnapshot = entry;
        pt.exitSnapshot = exit;
        pt.computeDiff();
        return pt;
    }

    @Test
    void identicalSnapshotsProduceEmptyChangedFields() {
        Map<String, String> snap = new LinkedHashMap<>(Map.of("orderId", "null", "status", "null"));
        TransformRecord.ParameterTransform pt = makeParamTransform(snap, snap);
        assertTrue(pt.changedFields.isEmpty());
        assertFalse(pt.mutated);
    }

    @Test
    void changedFieldDetected() {
        Map<String, String> entry = new LinkedHashMap<>();
        entry.put("orderId", "null");
        entry.put("status", "null");

        Map<String, String> exit = new LinkedHashMap<>();
        exit.put("orderId", "ord-456");
        exit.put("status", "PROCESSING");

        TransformRecord.ParameterTransform pt = makeParamTransform(entry, exit);
        List<String> fieldNames = pt.changedFields.stream()
            .map(d -> d.field).toList();
        assertTrue(fieldNames.contains("orderId"));
        assertTrue(fieldNames.contains("status"));
        assertTrue(pt.mutated);

        // Verify before/after values are captured
        TransformRecord.FieldDiff orderIdDiff = pt.changedFields.stream()
            .filter(d -> "orderId".equals(d.field)).findFirst().orElseThrow();
        assertEquals("null", orderIdDiff.before);
        assertEquals("ord-456", orderIdDiff.after);
    }

    @Test
    void mutatedTrueWhenChangedFieldsNonEmpty() {
        Map<String, String> entry = new LinkedHashMap<>(Map.of("x", "1"));
        Map<String, String> exit  = new LinkedHashMap<>(Map.of("x", "2"));
        TransformRecord.ParameterTransform pt = makeParamTransform(entry, exit);
        assertTrue(pt.mutated);
        assertFalse(pt.changedFields.isEmpty());
    }

    @Test
    void mutatedFalseWhenNoChanges() {
        Map<String, String> snap = new LinkedHashMap<>(Map.of("x", "1"));
        TransformRecord.ParameterTransform pt = makeParamTransform(snap, snap);
        assertFalse(pt.mutated);
        assertTrue(pt.changedFields.isEmpty());
    }

    @Test
    void gsonRoundTrip() {
        TransformRecord record = new TransformRecord();
        record.symbolId    = "java::com.example.Foo::bar(String)";
        record.returnType  = "OrderResponse";
        record.returnValue = "OrderResponse{orderId=ord-123, status=CONFIRMED}";

        TransformRecord.ParameterTransform pt = new TransformRecord.ParameterTransform();
        pt.name      = "request";
        pt.typeName  = "OrderRequest";
        pt.entrySnapshot = new LinkedHashMap<>(Map.of("orderId", "null"));
        pt.exitSnapshot  = new LinkedHashMap<>(Map.of("orderId", "ord-123"));
        pt.computeDiff();
        record.parameters = List.of(pt);

        Gson gson = new Gson();
        String json = gson.toJson(record);
        TransformRecord deserialized = gson.fromJson(json, TransformRecord.class);

        assertEquals(record.symbolId, deserialized.symbolId);
        assertEquals(1, deserialized.parameters.size());
        assertEquals("request", deserialized.parameters.get(0).name);
        assertEquals("OrderResponse{orderId=ord-123, status=CONFIRMED}", deserialized.returnValue);
    }

    @Test
    void renderSnapshotEmpty() {
        String rendered = TransformRecord.renderSnapshot("Foo", new LinkedHashMap<>());
        assertEquals("Foo{}", rendered);
    }

    @Test
    void renderSnapshotWithFields() {
        Map<String, String> snap = new LinkedHashMap<>();
        snap.put("orderId", "ord-123");
        snap.put("status", "CONFIRMED");
        String rendered = TransformRecord.renderSnapshot("OrderResponse", snap);
        assertEquals("OrderResponse{orderId=ord-123, status=CONFIRMED}", rendered);
    }
}
