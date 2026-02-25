package com.contextslice.agent;

import com.google.gson.annotations.SerializedName;
import java.util.*;

/**
 * Represents the data transformation record for a single method invocation.
 * Serialized as an entry in the {@code method_transforms} array in runtime_trace.json.
 *
 * JSON schema:
 * {
 *   "symbol_id": "java::...",
 *   "parameters": [
 *     {
 *       "name": "request",
 *       "type_name": "OrderRequest",
 *       "mutated": true,
 *       "changed_fields": [
 *         {"field": "orderId", "before": "null", "after": "ord-456"},
 *         ...
 *       ]
 *     }
 *   ],
 *   "return_value": "OrderResponse{orderId=ord-456, status=CONFIRMED}",  // null if void
 *   "return_type": "OrderResponse"  // null if void
 * }
 */
public class TransformRecord {

    @SerializedName("symbol_id")
    public String symbolId;

    @SerializedName("parameters")
    public List<ParameterTransform> parameters;

    /** Compact rendered form of the return value snapshot. Null if method is void. */
    @SerializedName("return_value")
    public String returnValue;

    @SerializedName("return_type")
    public String returnType;

    // ---------------------------------------------------------------------------

    public static class ParameterTransform {
        @SerializedName("name")
        public String name;

        @SerializedName("type_name")
        public String typeName;

        @SerializedName("mutated")
        public boolean mutated;

        @SerializedName("changed_fields")
        public List<FieldDiff> changedFields;

        // Transient: used only during diff computation; not written to JSON
        public transient Map<String, String> entrySnapshot;
        public transient Map<String, String> exitSnapshot;

        /**
         * Computes field-level diffs between entrySnapshot and exitSnapshot.
         * Populates changedFields and sets mutated.
         */
        public void computeDiff() {
            changedFields = new ArrayList<>();
            Set<String> allKeys = new LinkedHashSet<>();
            if (entrySnapshot != null) allKeys.addAll(entrySnapshot.keySet());
            if (exitSnapshot  != null) allKeys.addAll(exitSnapshot.keySet());

            for (String key : allKeys) {
                String before = entrySnapshot != null ? entrySnapshot.getOrDefault(key, "null") : "null";
                String after  = exitSnapshot  != null ? exitSnapshot.getOrDefault(key,  "null") : "null";
                if (!Objects.equals(before, after)) {
                    FieldDiff diff = new FieldDiff();
                    diff.field  = key;
                    diff.before = before;
                    diff.after  = after;
                    changedFields.add(diff);
                }
            }
            mutated = !changedFields.isEmpty();
        }
    }

    // ---------------------------------------------------------------------------

    public static class FieldDiff {
        @SerializedName("field")  public String field;
        @SerializedName("before") public String before;
        @SerializedName("after")  public String after;
    }

    // ---------------------------------------------------------------------------

    /**
     * Renders a Map<String,String> snapshot as a compact human-readable string.
     * Example: "OrderResponse{orderId=ord-456, status=CONFIRMED}"
     */
    public static String renderSnapshot(String typeName, Map<String, String> snapshot) {
        if (snapshot == null || snapshot.isEmpty()) return typeName + "{}";
        StringBuilder sb = new StringBuilder(typeName).append('{');
        boolean first = true;
        for (Map.Entry<String, String> e : snapshot.entrySet()) {
            if (!first) sb.append(", ");
            sb.append(e.getKey()).append('=').append(e.getValue());
            first = false;
        }
        sb.append('}');
        return sb.toString();
    }
}
