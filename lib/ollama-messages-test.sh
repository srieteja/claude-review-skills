#!/usr/bin/env bash
# Runs the finder tool-dispatch tests under the engine's suite runner.
set -euo pipefail
exec python3 "$(dirname "$0")/ollama_messages_test.py"
