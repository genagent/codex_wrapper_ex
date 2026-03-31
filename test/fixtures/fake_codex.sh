#!/bin/sh
# Fake codex binary for testing.
# Echoes all arguments so tests can verify correct arg construction.
printf '%s\n' "$*"
