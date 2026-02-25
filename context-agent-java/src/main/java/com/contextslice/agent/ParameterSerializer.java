package com.contextslice.agent;

import java.lang.reflect.Array;
import java.lang.reflect.Field;
import java.util.*;

/**
 * Serializes an arbitrary Java object to a flat Map<String, String> snapshot.
 *
 * Rules:
 * - Primitives and String: {"value": String.valueOf(obj)}
 * - POJOs: {"fieldName": "fieldValue"} for each declared (and inherited) field
 * - Depth limit: when current depth >= depthLimit, emit the type name instead of recursing
 * - Collections and arrays: emit "length" + up to maxCollectionElements indexed entries
 * - Null object: return empty map
 * - Null field value: emit "null"
 * - Cycle detection: via IdentityHashMap — emit "<circular>" if re-visited
 * - Superclass fields: walks hierarchy up to (but not including) Object
 */
public final class ParameterSerializer {

    private ParameterSerializer() {}

    public static Map<String, String> serialize(Object obj, SerializerConfig config) {
        Map<String, String> result = new LinkedHashMap<>();
        if (obj == null) return result;
        IdentityHashMap<Object, Boolean> visited = new IdentityHashMap<>();
        serializeInto(obj, config, 0, "", result, visited);
        return result;
    }

    private static void serializeInto(
            Object obj,
            SerializerConfig config,
            int depth,
            String prefix,
            Map<String, String> out,
            IdentityHashMap<Object, Boolean> visited) {

        if (obj == null) {
            out.put(prefix.isEmpty() ? "value" : prefix, "null");
            return;
        }

        Class<?> cls = obj.getClass();

        // Primitives, boxed types, String — simple scalar
        if (isScalar(cls)) {
            String key = prefix.isEmpty() ? "value" : prefix;
            out.put(key, String.valueOf(obj));
            return;
        }

        // Cycle detection
        if (visited.containsKey(obj)) {
            String key = prefix.isEmpty() ? "value" : prefix;
            out.put(key, "<circular>");
            return;
        }

        // Arrays
        if (cls.isArray()) {
            serializeArray(obj, config, depth, prefix, out, visited);
            return;
        }

        // Collections
        if (obj instanceof Collection<?> col) {
            serializeCollection(col, config, depth, prefix, out, visited);
            return;
        }

        // Maps
        if (obj instanceof Map<?, ?> map) {
            serializeMap(map, config, depth, prefix, out, visited);
            return;
        }

        // At depth limit, emit type name only
        if (depth >= config.depthLimit) {
            String key = prefix.isEmpty() ? "value" : prefix;
            out.put(key, "<" + cls.getSimpleName() + ">");
            return;
        }

        // POJO: recurse into fields
        visited.put(obj, Boolean.TRUE);
        try {
            serializePojo(obj, cls, config, depth, prefix, out, visited);
        } finally {
            visited.remove(obj);
        }
    }

    private static void serializePojo(
            Object obj,
            Class<?> cls,
            SerializerConfig config,
            int depth,
            String prefix,
            Map<String, String> out,
            IdentityHashMap<Object, Boolean> visited) {

        // Walk class hierarchy (including superclasses) up to Object
        List<Field> fields = new ArrayList<>();
        Class<?> c = cls;
        while (c != null && c != Object.class) {
            for (Field f : c.getDeclaredFields()) {
                // Skip synthetic, static fields
                if (f.isSynthetic()) continue;
                if (java.lang.reflect.Modifier.isStatic(f.getModifiers())) continue;
                fields.add(f);
            }
            c = c.getSuperclass();
        }

        for (Field field : fields) {
            try {
                field.setAccessible(true);
            } catch (Exception e) {
                // Module system (Java 9+) may block setAccessible for fields in
                // java.base (e.g. java.lang.Enum.name). Skip inaccessible fields.
                continue;
            }
            String fieldKey = prefix.isEmpty() ? field.getName() : prefix + "." + field.getName();
            Object fieldValue;
            try {
                fieldValue = field.get(obj);
            } catch (IllegalAccessException e) {
                out.put(fieldKey, "<inaccessible>");
                continue;
            }

            if (fieldValue == null) {
                out.put(fieldKey, "null");
            } else if (isScalar(fieldValue.getClass())) {
                out.put(fieldKey, String.valueOf(fieldValue));
            } else if (depth + 1 >= config.depthLimit) {
                out.put(fieldKey, "<" + fieldValue.getClass().getSimpleName() + ">");
            } else {
                serializeInto(fieldValue, config, depth + 1, fieldKey, out, visited);
            }
        }
    }

    private static void serializeArray(
            Object arr,
            SerializerConfig config,
            int depth,
            String prefix,
            Map<String, String> out,
            IdentityHashMap<Object, Boolean> visited) {

        int len = Array.getLength(arr);
        String lenKey = prefix.isEmpty() ? "length" : prefix + ".length";
        out.put(lenKey, String.valueOf(len));
        int limit = Math.min(len, config.maxCollectionElements);
        for (int i = 0; i < limit; i++) {
            Object elem = Array.get(arr, i);
            String elemKey = prefix.isEmpty() ? "[" + i + "]" : prefix + "[" + i + "]";
            if (elem == null) {
                out.put(elemKey, "null");
            } else if (isScalar(elem.getClass())) {
                out.put(elemKey, String.valueOf(elem));
            } else if (depth + 1 >= config.depthLimit) {
                out.put(elemKey, "<" + elem.getClass().getSimpleName() + ">");
            } else {
                serializeInto(elem, config, depth + 1, elemKey, out, visited);
            }
        }
    }

    private static void serializeCollection(
            Collection<?> col,
            SerializerConfig config,
            int depth,
            String prefix,
            Map<String, String> out,
            IdentityHashMap<Object, Boolean> visited) {

        int len = col.size();
        String lenKey = prefix.isEmpty() ? "length" : prefix + ".length";
        out.put(lenKey, String.valueOf(len));
        int count = 0;
        for (Object elem : col) {
            if (count >= config.maxCollectionElements) break;
            String elemKey = prefix.isEmpty() ? "[" + count + "]" : prefix + "[" + count + "]";
            if (elem == null) {
                out.put(elemKey, "null");
            } else if (isScalar(elem.getClass())) {
                out.put(elemKey, String.valueOf(elem));
            } else if (depth + 1 >= config.depthLimit) {
                out.put(elemKey, "<" + elem.getClass().getSimpleName() + ">");
            } else {
                serializeInto(elem, config, depth + 1, elemKey, out, visited);
            }
            count++;
        }
    }

    private static void serializeMap(
            Map<?, ?> map,
            SerializerConfig config,
            int depth,
            String prefix,
            Map<String, String> out,
            IdentityHashMap<Object, Boolean> visited) {

        String lenKey = prefix.isEmpty() ? "length" : prefix + ".length";
        out.put(lenKey, String.valueOf(map.size()));
        int count = 0;
        for (Map.Entry<?, ?> entry : map.entrySet()) {
            if (count >= config.maxCollectionElements) break;
            String elemKey = prefix.isEmpty()
                ? "[" + entry.getKey() + "]"
                : prefix + "[" + entry.getKey() + "]";
            Object val = entry.getValue();
            if (val == null) {
                out.put(elemKey, "null");
            } else if (isScalar(val.getClass())) {
                out.put(elemKey, String.valueOf(val));
            } else if (depth + 1 >= config.depthLimit) {
                out.put(elemKey, "<" + val.getClass().getSimpleName() + ">");
            } else {
                serializeInto(val, config, depth + 1, elemKey, out, visited);
            }
            count++;
        }
    }

    static boolean isScalar(Class<?> cls) {
        return cls.isPrimitive()
            || cls == String.class
            || cls == Boolean.class
            || cls == Byte.class
            || cls == Short.class
            || cls == Integer.class
            || cls == Long.class
            || cls == Float.class
            || cls == Double.class
            || cls == Character.class
            || cls.isEnum()
            || Number.class.isAssignableFrom(cls) && cls.getPackageName().startsWith("java.");
    }
}
