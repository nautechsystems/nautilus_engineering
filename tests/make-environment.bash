#!/usr/bin/env bash
# Source before invoking fixture Make, including from a directly executed companion.
# These variables carry caller options, overrides, recursion state and extra Makefiles.
unset MAKEFLAGS MFLAGS MAKELEVEL GNUMAKEFLAGS MAKEOVERRIDES MAKEFILES
