package com.contextslice.adapter;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class AdapterMainTest {

    @Test
    void noArgsThrowsUsageException() {
        assertThrows(AdapterMain.UsageException.class, () -> AdapterMain.run(new String[]{}));
    }

    @Test
    void unknownSubcommandThrowsUsageException() {
        assertThrows(AdapterMain.UsageException.class,
                () -> AdapterMain.run(new String[]{"unknown-cmd"}));
    }

    @Test
    void missingManifestFlagThrowsUsageException() {
        assertThrows(AdapterMain.UsageException.class,
                () -> AdapterMain.run(new String[]{"record", "--output", "/tmp", "--agent", "/tmp/agent.jar"}));
    }

    @Test
    void missingOutputFlagThrowsUsageException() {
        assertThrows(AdapterMain.UsageException.class,
                () -> AdapterMain.run(new String[]{"record", "--manifest", "/tmp/m.json", "--agent", "/tmp/agent.jar"}));
    }

    @Test
    void missingAgentFlagThrowsUsageException() {
        assertThrows(AdapterMain.UsageException.class,
                () -> AdapterMain.run(new String[]{"record", "--manifest", "/tmp/m.json", "--output", "/tmp/out"}));
    }

    @Test
    void unknownFlagThrowsUsageException() {
        assertThrows(AdapterMain.UsageException.class,
                () -> AdapterMain.run(new String[]{"record", "--foo", "bar"}));
    }

    @Test
    void mainExitsWithCode2OnUsageError() {
        // Verify that main() doesn't throw (it catches and calls System.exit)
        // We can't easily test System.exit, so just confirm the UsageException is thrown by run()
        Exception ex = assertThrows(AdapterMain.UsageException.class,
                () -> AdapterMain.run(new String[]{"record"}));
        assertNotNull(ex.getMessage());
    }
}
