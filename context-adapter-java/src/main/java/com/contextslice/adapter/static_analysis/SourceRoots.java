package com.contextslice.adapter.static_analysis;

import java.util.List;

/**
 * Result of source root resolution: the main source directory and classpath JARs.
 */
public record SourceRoots(
    String sourceRoot,          // absolute path to src/main/java (or equivalent)
    List<String> classpathJars  // absolute paths to all dependency JARs
) {}
