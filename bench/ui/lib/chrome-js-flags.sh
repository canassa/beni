#!/usr/bin/env bash
# Chromium with extra V8 flags, for `--chrome=lib/chrome-js-flags.sh`:
# BENCH_JS_FLAGS="--always-sparkplug" replaces the harness's
# `--js-flags=--expose-gc` (Chromium keeps the last --js-flags), keeping
# --expose-gc. Research 59 uses it to ask how much of a cost is V8's tiers.
exec chromium "$@" "--js-flags=--expose-gc ${BENCH_JS_FLAGS:-}"
