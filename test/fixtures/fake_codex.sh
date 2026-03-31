#!/bin/sh
# Fake codex binary for unit tests.
# Echoes arguments so tests can assert on them.
# Special-cases --version to return a realistic version string.

for arg in "$@"; do
  if [ "$arg" = "--version" ]; then
    echo "codex 0.1.0"
    exit 0
  fi
done

echo "$@"
