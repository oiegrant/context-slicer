package com.contextslice.agent;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AgentBootstrapTest {

    @Test
    void parseArgsDefaults() {
        AgentBootstrap.AgentConfig config = AgentBootstrap.parseArgs(null);
        assertNotNull(config.outputPath());
        assertEquals("com.", config.namespace());
    }

    @Test
    void parseArgsOutput() {
        AgentBootstrap.AgentConfig config = AgentBootstrap.parseArgs("output=/tmp/trace");
        assertEquals("/tmp/trace", config.outputPath());
    }

    @Test
    void parseArgsNamespace() {
        AgentBootstrap.AgentConfig config = AgentBootstrap.parseArgs("namespace=com.mycompany");
        assertEquals("com.mycompany", config.namespace());
    }

    @Test
    void parseArgsBoth() {
        AgentBootstrap.AgentConfig config = AgentBootstrap.parseArgs("output=/tmp/out,namespace=com.example");
        assertEquals("/tmp/out", config.outputPath());
        assertEquals("com.example", config.namespace());
    }

    @Test
    void parseArgsBlankString() {
        AgentBootstrap.AgentConfig config = AgentBootstrap.parseArgs("   ");
        assertEquals("com.", config.namespace());
    }

    // --- Phase 13: transforms args ---

    @Test
    void parseArgsDefaultsIncludeTransforms() {
        AgentBootstrap.AgentConfig config = AgentBootstrap.parseArgs(null);
        assertTrue(config.transformsEnabled());
        assertEquals(2, config.depthLimit());
        assertEquals(3, config.maxCollectionElements());
    }

    @Test
    void parseArgsTransformsFalse() {
        AgentBootstrap.AgentConfig config = AgentBootstrap.parseArgs("transforms=false");
        assertFalse(config.transformsEnabled());
    }

    @Test
    void parseArgsDepth() {
        AgentBootstrap.AgentConfig config = AgentBootstrap.parseArgs("depth=3");
        assertEquals(3, config.depthLimit());
    }

    @Test
    void parseArgsMaxElements() {
        AgentBootstrap.AgentConfig config = AgentBootstrap.parseArgs("max_elements=1");
        assertEquals(1, config.maxCollectionElements());
    }

    @Test
    void parseArgsAllTransformArgs() {
        AgentBootstrap.AgentConfig config = AgentBootstrap.parseArgs(
            "output=/tmp,namespace=com.example,transforms=false,depth=4,max_elements=5");
        assertEquals("/tmp", config.outputPath());
        assertEquals("com.example", config.namespace());
        assertFalse(config.transformsEnabled());
        assertEquals(4, config.depthLimit());
        assertEquals(5, config.maxCollectionElements());
    }

    // --- Public accessor methods (safe for ByteBuddy inlined advice) ---

    @Test
    void accessorsReturnDefaultsWhenConfigNull() {
        AgentBootstrap.AgentConfig saved = AgentBootstrap.agentConfig;
        try {
            AgentBootstrap.agentConfig = null;
            assertFalse(AgentBootstrap.isTransformsEnabled());
            assertEquals(2, AgentBootstrap.getDepthLimit());
            assertEquals(3, AgentBootstrap.getMaxCollectionElements());
        } finally {
            AgentBootstrap.agentConfig = saved;
        }
    }

    @Test
    void accessorsReflectInstalledConfig() {
        AgentBootstrap.AgentConfig saved = AgentBootstrap.agentConfig;
        try {
            AgentBootstrap.agentConfig = AgentBootstrap.parseArgs(
                "transforms=true,depth=5,max_elements=10");
            assertTrue(AgentBootstrap.isTransformsEnabled());
            assertEquals(5, AgentBootstrap.getDepthLimit());
            assertEquals(10, AgentBootstrap.getMaxCollectionElements());
        } finally {
            AgentBootstrap.agentConfig = saved;
        }
    }

    @Test
    void accessorIsTransformsEnabledFalseWhenDisabled() {
        AgentBootstrap.AgentConfig saved = AgentBootstrap.agentConfig;
        try {
            AgentBootstrap.agentConfig = AgentBootstrap.parseArgs("transforms=false");
            assertFalse(AgentBootstrap.isTransformsEnabled());
        } finally {
            AgentBootstrap.agentConfig = saved;
        }
    }
}
