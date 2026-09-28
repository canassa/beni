/* The thread-local variable LLVM's SanitizerCoverage stack-depth tracking
 * writes in every instrumented function. Zig's LLVM backend always turns
 * that tracking on with coverage instrumentation, and a runtime normally
 * defines the variable; a Zig `export threadlocal` of the same name clashes
 * with the declaration LLVM adds and is renamed, so it is defined here, in
 * C. Its value is never read. */
__thread unsigned long __sancov_lowest_stack;
