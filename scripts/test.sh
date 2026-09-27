#!/usr/bin/env bash
# Runs the unit tests and the localization check.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sdk.sh
swift test ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} "$@"
python3 scripts/check-l10n.py
