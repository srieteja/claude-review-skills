#!/usr/bin/env bash
# Runs the python unit tests for review_learn.py (the learn step's effort clamp and parsing).
# review-skills test discovers *-test.sh only, so this wrapper is what puts them in the run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "learn-test: python3 not found" >&2; exit 1; }
cd "$HERE" && exec python3 -m unittest -q test_review_learn
