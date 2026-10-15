#!/usr/bin/env bash
exec taskset -c 2-5,8-11 "${S8_CHROME:?}" "$@"
