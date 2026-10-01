#!/usr/bin/env bash
# Fluxline setup wizard on Podman: UI + agent + Postgres from the published images. Run it from a
# clone, or straight from GitHub (fetches fluxline-setup.sh, the shared part, on the fly):
#   bash <(curl -fsSL https://raw.githubusercontent.com/shantanusune/fluxline/main/setup-podman.sh)
# Arguments: [up|status|down] [--yes] [--remote <ui-url>] — see fluxline-setup.sh.
set -euo pipefail
raw=https://raw.githubusercontent.com/shantanusune/fluxline/main
core="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/fluxline-setup.sh"
self="$0"
if [ ! -f "${core}" ]; then
  core="$(mktemp)"
  trap 'rm -f "${core}"' EXIT
  curl -fsSL "${raw}/fluxline-setup.sh" -o "${core}"
  self="bash <(curl -fsSL ${raw}/setup-podman.sh)"
fi
FLUXLINE_WRAPPER="${self}" bash "${core}" podman "$@"
