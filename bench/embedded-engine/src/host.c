// A minimal embedding of QuickJS / QuickJS-ng: runs an ES module tree from
// disk, with a synthetic node:process, no Date and no Math.random unless
// asked for. Usage: qhost [--date] [--random] [--repeat N] entry.mjs
// Exit: the program's process.exitCode, 1 on an uncaught throw.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "quickjs.h"
#include "prelude.h"

static const char *process_src = "export default globalThis.process;\n";
static const char *fs_src =
    "export const readFile = () => Promise.reject(new Error('qhost: no file system'));\n";

static int last_exception(JSContext *ctx) {
    JSValue e = JS_GetException(ctx);
    const char *s = JS_ToCString(ctx, e);
    fprintf(stderr, "uncaught: %s\n", s ? s : "?");
    if (s) JS_FreeCString(ctx, s);
    if (JS_IsObject(e)) {
        JSValue st = JS_GetPropertyStr(ctx, e, "stack");
        if (!JS_IsUndefined(st)) {
            const char *t = JS_ToCString(ctx, st);
            if (t) { fprintf(stderr, "%s\n", t); JS_FreeCString(ctx, t); }
        }
        JS_FreeValue(ctx, st);
    }
    JS_FreeValue(ctx, e);
    return 1;
}

static JSValue js_write(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int fd; size_t len;
    JS_ToInt32(ctx, &fd, argv[0]);
    const char *s = JS_ToCStringLen(ctx, &len, argv[1]);
    if (!s) return JS_EXCEPTION;
    fwrite(s, 1, len, fd == 2 ? stderr : stdout);
    JS_FreeCString(ctx, s);
    return JS_UNDEFINED;
}

static char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char *buf = malloc(n + 1);
    if (fread(buf, 1, n, f) != (size_t)n) { fclose(f); free(buf); return NULL; }
    fclose(f); buf[n] = 0; *len = n;
    return buf;
}

static JSModuleDef *loader(JSContext *ctx, const char *name, void *opaque) {
    const char *src = NULL; char *owned = NULL; size_t len = 0;
    if (strcmp(name, "node:process") == 0) src = process_src;
    else if (strcmp(name, "node:fs/promises") == 0) src = fs_src;
    else {
        owned = read_file(name, &len);
        if (!owned) { JS_ThrowReferenceError(ctx, "could not load module '%s'", name); return NULL; }
        src = owned;
    }
    if (!owned) len = strlen(src);
    JSValue m = JS_Eval(ctx, src, len, name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    free(owned);
    if (JS_IsException(m)) return NULL;
    JSModuleDef *def = JS_VALUE_GET_PTR(m);
    JS_FreeValue(ctx, m);
    return def;
}

static int drain(JSContext *ctx, JSRuntime *rt) {
    JSContext *c;
    for (;;) {
        int r = JS_ExecutePendingJob(rt, &c);
        if (r < 0) return last_exception(c);
        if (r == 0) return 0;
    }
}

// Calls a global function of no arguments; its truth, or 0 with *status set
// on a throw.
static int call_bool(JSContext *ctx, JSValue global, const char *name, int *status) {
    JSValue f = JS_GetPropertyStr(ctx, global, name);
    JSValue r = JS_Call(ctx, f, global, 0, NULL);
    JS_FreeValue(ctx, f);
    if (JS_IsException(r)) { *status = last_exception(ctx); return 0; }
    int b = JS_ToBool(ctx, r);
    JS_FreeValue(ctx, r);
    return b;
}

static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static int run_once(const char *entry, int with_date, int with_random, double *t_start, double *t_run) {
    double t0 = now_ms();
    JSRuntime *rt = JS_NewRuntime();
    JS_SetMaxStackSize(rt, 4 * 1024 * 1024);
    JSContext *ctx = JS_NewContextRaw(rt);
    JS_AddIntrinsicBaseObjects(ctx);
    JS_AddIntrinsicEval(ctx);
    if (with_date) JS_AddIntrinsicDate(ctx);
    JS_AddIntrinsicRegExp(ctx);
#ifndef QJS_NG
    JS_AddIntrinsicStringNormalize(ctx);
#endif
    JS_AddIntrinsicJSON(ctx);
    JS_AddIntrinsicProxy(ctx);
    JS_AddIntrinsicMapSet(ctx);
    JS_AddIntrinsicTypedArrays(ctx);
    JS_AddIntrinsicPromise(ctx);
    JS_AddIntrinsicWeakRef(ctx);
#ifdef QJS_NG
    JS_AddIntrinsicBigInt(ctx);
#endif
    JS_SetModuleLoaderFunc(rt, NULL, loader, NULL);
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__write", JS_NewCFunction(ctx, js_write, "__write", 2));
    JS_SetPropertyStr(ctx, global, "__exitCode", JS_NewInt32(ctx, 0));
    if (!with_random) {
        JSValue math = JS_GetPropertyStr(ctx, global, "Math");
        JSAtom a = JS_NewAtom(ctx, "random");
        JS_DeleteProperty(ctx, math, a, 0);
        JS_FreeAtom(ctx, a);
        JS_FreeValue(ctx, math);
    }
    JSValue r = JS_Eval(ctx, (const char *)prelude_js, prelude_js_len, "<prelude>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(r)) return last_exception(ctx);
    JS_FreeValue(ctx, r);
    JSValue tick = JS_GetPropertyStr(ctx, global, "__tick");
    double t1 = now_ms();

    size_t len; char *src = read_file(entry, &len);
    if (!src) { fprintf(stderr, "cannot read %s\n", entry); return 2; }
    JSValue p = JS_Eval(ctx, src, len, entry, JS_EVAL_TYPE_MODULE);
    free(src);
    int status = 0;
    if (JS_IsException(p)) { status = last_exception(ctx); goto out; }
    for (;;) {
        if ((status = drain(ctx, rt))) goto out;
        JSValue more = JS_Call(ctx, tick, global, 0, NULL);
        if (JS_IsException(more)) { status = last_exception(ctx); goto out; }
        int go = JS_ToBool(ctx, more);
        JS_FreeValue(ctx, more);
        if (go) continue;
        if (!call_bool(ctx, global, "__beforeExit", &status)) break;
        if (status) goto out;
        if ((status = drain(ctx, rt))) goto out;
        if (!call_bool(ctx, global, "__pending", &status)) break;
        if (status) goto out;
    }
    if (JS_PromiseState(ctx, p) == JS_PROMISE_REJECTED) {
        JSValue reason = JS_PromiseResult(ctx, p);
        JS_Throw(ctx, reason);
        status = last_exception(ctx);
        goto out;
    }
    {
        JSValue code = JS_GetPropertyStr(ctx, global, "__exitCode");
        JS_ToInt32(ctx, &status, code);
        JS_FreeValue(ctx, code);
    }
out:
    fflush(stdout);
    JS_FreeValue(ctx, p);
    JS_FreeValue(ctx, tick);
    JS_FreeValue(ctx, global);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    double t2 = now_ms();
    if (t_start) *t_start = t1 - t0;
    if (t_run) *t_run = t2 - t1;
    return status;
}

int main(int argc, char **argv) {
    int with_date = 0, with_random = 0, repeat = 1;
    const char *entry = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--date")) with_date = 1;
        else if (!strcmp(argv[i], "--random")) with_random = 1;
        else if (!strcmp(argv[i], "--repeat")) repeat = atoi(argv[++i]);
        else entry = argv[i];
    }
    if (!entry) { fprintf(stderr, "usage: qhost [--date] [--random] [--repeat N] entry.mjs\n"); return 2; }
    int status = 0;
    for (int i = 0; i < repeat; i++) {
        double ts, tr;
        status = run_once(entry, with_date, with_random, &ts, &tr);
        if (repeat > 1) fprintf(stderr, "run %d: start %.3f ms, run %.3f ms\n", i, ts, tr);
    }
    return status;
}
