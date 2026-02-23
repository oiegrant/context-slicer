// This file lives at the repo root so its package path covers both JAR directories.
// It is added as a named import ("embedded_jars") in context-slicer/build.zig.
pub const adapter = @embedFile("context-adapter-java/target/context-adapter-java-0.1.0.jar");
pub const agent   = @embedFile("context-agent-java/target/context-agent-java-0.1.0.jar");
