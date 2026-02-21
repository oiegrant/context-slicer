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
}
