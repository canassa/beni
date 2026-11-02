---
title: Developer Documentation (FFmpeg)
source: https://ffmpeg.org/developer.html
retrieved: 2026-11-02
note: does NOT contain the "proudly written in C ... fashionable languages" sentence; kept as the official statement on languages
---

31-- [1 Introduction](#Introduction)
32-- [2 Coding Rules](#Coding-Rules-1)
33:  - [2.1 Language](#Language)
34-    - [2.1.1 SIMD/DSP](#SIMD_002fDSP-1)
35:    - [2.1.2 Other languages](#Other-languages)
36-  - [2.2 Code formatting conventions](#Code-formatting-conventions)
37-    - [2.2.1 Examples](#Examples)
38-    - [2.2.2 Vim configuration](#Vim-configuration)
39-    - [2.2.3 Emacs configuration](#Emacs-configuration)
40-  - [2.3 Comments](#Comments)
41-  - [2.4 Naming conventions](#Naming-conventions-1)
--
85-## 2 Coding Rules[\#](#Coding-Rules-1) [TOC](#toc-Coding-Rules-1)
86-
87:### 2.1 Language[\#](#Language) [TOC](#toc-Language)
88-
89:FFmpeg is mainly programmed in the ISO C11 language, except for the public headers which must stay C99 compatible.
90-
91-Compiler-specific extensions may be used with good reason, but must not be depended on, i.e. the code must still compile and work with compilers lacking the extension.
92-
93-The following C99 features must not be used anywhere in the codebase:
94-
95-- variable-length arrays;
--
107-A unit testing framework for assembly called `checkasm` lives under `tests/checkasm`. All new assembly should come with `checkasm` tests; adding tests for existing assembly that lacks them is also strongly encouraged.
108-
109:#### 2.1.2 Other languages[\#](#Other-languages) [TOC](#toc-Other-languages)
110-
111:Other languages than C may be used in special cases:
112-
113-- Compiler intrinsics or inline assembly when the code in question cannot be written in the standard way described in the [SIMD/DSP](#SIMD_002fDSP) section. This typically applies to code that needs to be inlined.
114-- Objective-C where required for interacting with macOS-specific interfaces.
115-
116-### 2.2 Code formatting conventions[\#](#Code-formatting-conventions) [TOC](#toc-Code-formatting-conventions)
117-
