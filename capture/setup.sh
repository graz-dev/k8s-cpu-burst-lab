#!/usr/bin/env bash
# Installs Playwright and Chromium into capture/out/venv.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -m venv "${ROOT}/out/venv"
"${ROOT}/out/venv/bin/pip" install --quiet playwright
"${ROOT}/out/venv/bin/playwright" install chromium
