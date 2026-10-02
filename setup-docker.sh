#!/usr/bin/env bash
# Fluxline setup wizard on Docker: UI, agent and Postgres from the fluxline-standalone image. Run it from a
# clone, or straight from GitHub (fetches fluxline-setup.sh, the shared part, on the fly):
#   bash <(curl -fsSL https://raw.githubusercontent.com/shantanusune/fluxline/main/setup-docker.sh)
# Arguments: [up|status|down] [--yes] [--remote <ui-url>] — see fluxline-setup.sh.
# Started as `sh setup-docker.sh` where sh isn't bash (dash on Debian/Ubuntu): run again under bash.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
raw=https://raw.githubusercontent.com/shantanusune/fluxline/main
core="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/fluxline-setup.sh"
self="$0"
if [ ! -f "${core}" ]; then
  core="$(mktemp)"
  trap 'rm -f "${core}"' EXIT
  curl -fsSL "${raw}/fluxline-setup.sh" -o "${core}"
  self="bash <(curl -fsSL ${raw}/setup-docker.sh)"
fi
FLUXLINE_WRAPPER="${self}" bash "${core}" docker "$@"
