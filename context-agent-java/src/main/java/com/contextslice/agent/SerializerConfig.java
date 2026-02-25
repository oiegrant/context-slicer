package com.contextslice.agent;

/**
 * Configuration for ParameterSerializer — sourced from context-slice.json via agent args.
 */
public class SerializerConfig {

    /** Maximum object graph depth to recurse. At this depth, emit the type name only. */
    public final int depthLimit;

    /** Maximum collection elements to serialize before truncating. */
    public final int maxCollectionElements;

    public SerializerConfig(int depthLimit, int maxCollectionElements) {
        this.depthLimit = depthLimit;
        this.maxCollectionElements = maxCollectionElements;
    }

    public static SerializerConfig defaults() {
        return new SerializerConfig(2, 3);
    }
}
