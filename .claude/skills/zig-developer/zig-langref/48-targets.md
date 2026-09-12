# Targets


**Target** refers to the computer that will be used to run an executable. It is composed of the CPU architecture, the set of enabled CPU features, operating system, minimum and maximum operating system version, ABI, and ABI version.

Zig is a general-purpose programming language which means that it is designed to generate optimal code for a large set of targets. The command `zig targets` provides information about all of the targets the compiler is aware of.

When no target option is provided to the compiler, the default choice is to target the **host computer**, meaning that the resulting executable will be *unsuitable for copying to a different computer*. In order to copy an executable to another computer, the compiler needs to know about the target requirements via the `-target` option.

The Zig Standard Library (`@import``(``"std"``)`) has cross-platform abstractions, making the same source code viable on many targets. Some code is more portable than other code. In general, Zig code is extremely portable compared to other programming languages.

Each platform requires its own implementations to make Zig's cross-platform abstractions work. These implementations are at various degrees of completion. Each tagged release of the compiler comes with release notes that provide the full support table for each target.

