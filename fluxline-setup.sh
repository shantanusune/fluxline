#!/usr/bin/env bash
# Fluxline setup wizard: starts Fluxline (UI, agent and its Postgres, all in the one
# fluxline-standalone image) on Docker or Podman. Asks two things: your code folder and,
# optionally, an Anthropic API key. Everything else is generated or detected. Nothing needs sudo;
# rootless Podman works.
#
#   ./setup-podman.sh                     # or ./setup-docker.sh
#   ./setup-podman.sh --yes               # no questions at all
#   ./setup-podman.sh --remote https://fluxline.yourco.com
#                                                      # agent only, linked to a hosted UI
#   ./setup-podman.sh status              # what's running; can the agent reach the engine
#   ./setup-podman.sh down                # remove the container (data is kept)
#   ./setup-podman.sh --clean             # wipe everything (data, saved keys, login) and start fresh
#   ./setup-podman.sh down --clean        # wipe everything without starting again
#
# Optional environment variables:
#   FLUXLINE_REGISTRY   where the image comes from (default docker.io/suneshantanu), for a mirror
#   FLUXLINE_IMAGE      run this exact image (e.g. a local test build)
#   FLUXLINE_PULL=0     use the image already on this machine instead of pulling (local testing)
#   FLUXLINE_DEBUG=1    print the exact container command (no secret values)
#   UI_PORT, AGENT_PORT host ports (default 3000, 3400)
#   ADMIN_EMAIL, ADMIN_PASSWORD, OPENAI_API_KEY, FLUXLINE_TOOLCHAIN=0 (never mount the engine socket),
#   FLUXLINE_VSCODE=0   don't install the VS Code bridge extension
#   FLUXLINE_NAME       name of the container and prefix of its volumes (default fluxline), e.g. to
#                       run a second, separate copy; FLUXLINE_HOME moves the saved answers
#
# VS Code: when the `code` CLI is found, the bridge extension is installed from the UI. The agent
# finds the bridge by itself (connection_mode: auto — the bridge's socket on Linux, the host gateway
# on macOS/Windows) through the host's ~/.ai-sdlc mounted into the container; nothing to configure.
#
# Answers and the admin password are saved in ~/.fluxline/setup.env (mode 600), so re-running keeps
# the same data and login.
#
# Engine socket: the agent runs build/test checks in sibling toolchain containers through the
# `docker` CLI, which needs the engine's API socket mounted at /var/run/docker.sock. Under Podman
# that socket lives elsewhere (on macOS, inside the Podman machine VM), so the wizard tries
# /var/run/docker.sock first, then Podman's own socket, and keeps whichever a test container can
# actually use. Under rootless Podman this grants nothing beyond what your own user already has.
set -euo pipefail

# FLUXLINE_SETUP_LIB=1: only define the functions (tests source this file).
if [ "${FLUXLINE_SETUP_LIB:-}" = 1 ]; then
  RUNTIME=podman
  set -- up
else
  RUNTIME="${1:-}"
  shift || true
fi
case "${RUNTIME}" in
  docker | podman) ;;
  *)
    echo "Usage: $0 <docker|podman> [up|status|down] [--yes] [--clean] [--remote <ui-url>]" >&2
    exit 2
    ;;
esac

ACTION=up
ASSUME_YES=0
EXPLICIT_YES=0
CLEAN=0
CLI_REMOTE_UI_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    up | status | down) ACTION="$1" ;;
    -y | --yes) ASSUME_YES=1 EXPLICIT_YES=1 ;;
    --clean) CLEAN=1 ;;
    --remote)
      [ $# -ge 2 ] || { echo "--remote needs the hosted UI's address" >&2; exit 2; }
      CLI_REMOTE_UI_URL="$2"
      shift
      ;;
    -h | --help)
      sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done
[ -t 0 ] || ASSUME_YES=1

SELF="${FLUXLINE_WRAPPER:-$0 ${RUNTIME}}"
STATE_DIR="${FLUXLINE_HOME:-$HOME/.fluxline}"
STATE_FILE="${STATE_DIR}/setup.env"
REGISTRY="${FLUXLINE_REGISTRY:-docker.io/suneshantanu}"
NAME="${FLUXLINE_NAME:-fluxline}"
CONTAINER="${NAME}"
DATA_VOLUME="${NAME}-data"
PG_VOLUME="${NAME}-postgres"
# Containers of the earlier three-container setup, replaced by the one container above.
LEGACY_CONTAINERS="${NAME}-ui ${NAME}-agent ${NAME}-db"
OS="$(uname -s)"

# --- output and prompts ------------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RESET=$'\033[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' RESET=''
fi
step() { printf '\n%s==> %s%s\n' "${BOLD}" "$*" "${RESET}"; }
ok() { printf '  %s✓%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn() { printf '  %s!%s %s\n' "${YELLOW}" "${RESET}" "$*"; }
die() {
  printf '\n%sError:%s %s\n' "${RED}" "${RESET}" "$*" >&2
  exit 1
}

# ask VAR "Question" "default" — an already-set VAR (environment or saved answer) is the default.
ask() {
  local var="$1" question="$2" fallback="${3:-}" current reply
  current="${!var:-$fallback}"
  if [ "${ASSUME_YES}" = 0 ]; then
    if [ -n "${current}" ]; then
      read -r -p "  ${question} [${current}]: " reply || true
    else
      read -r -p "  ${question}: " reply || true
    fi
    current="${reply:-$current}"
  fi
  printf -v "${var}" '%s' "${current}"
}

# ask_secret VAR "Question" — hidden input; Enter keeps the current value (possibly empty).
ask_secret() {
  local var="$1" question="$2" reply
  [ "${ASSUME_YES}" = 1 ] && return 0
  read -r -s -p "  ${question}: " reply || true
  echo
  [ -n "${reply}" ] && printf -v "${var}" '%s' "${reply}"
  return 0
}

confirm() {
  local reply
  [ "${ASSUME_YES}" = 1 ] && return 0
  read -r -p "  $1 [Y/n]: " reply || true
  case "${reply}" in [nN]*) return 1 ;; *) return 0 ;; esac
}

# confirm_destructive "Question" — default No: only an explicit y/yes goes ahead (or --yes).
confirm_destructive() {
  local reply=""
  [ "${EXPLICIT_YES}" = 1 ] && return 0
  # Not a terminal and no --yes: never assume consent to delete.
  [ -t 0 ] || return 1
  read -r -p "  $1 [y/N]: " reply || true
  case "${reply}" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

random_token() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}" || true; }
rt() { "${RUNTIME}" "$@"; }
exists() { rt container inspect "$1" >/dev/null 2>&1; }

STATE_KEYS="REMOTE_UI_URL REMOTE_AGENT_TOKEN WORKSPACE ADMIN_EMAIL ADMIN_PASSWORD AGENT_API_TOKEN
  ANTHROPIC_API_KEY OPENAI_API_KEY UI_PORT AGENT_PORT"

save_state() {
  mkdir -p "${STATE_DIR}"
  (
    umask 077
    echo "# Written by fluxline-setup.sh. ADMIN_PASSWORD is the login of the first admin account."
    for key in ${STATE_KEYS}; do printf '%s=%q\n' "${key}" "${!key:-}"; done
  ) >"${STATE_FILE}"
  chmod 600 "${STATE_FILE}"
}

load_state() {
  [ -f "${STATE_FILE}" ] || return 0
  local line key
  while IFS= read -r line; do
    case "${line}" in '#'* | '') continue ;; esac
    key="${line%%=*}"
    case " ${STATE_KEYS} " in *[[:space:]]"${key}"[[:space:]]*) ;; *) continue ;; esac
    [ -n "${!key:-}" ] && continue # environment variables win over saved answers
    eval "${line}"
  done <"${STATE_FILE}"
}

# HTTP status of a URL, or 000 when nothing answers.
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true; }
# The agent requires a token, so 401 still means it's up.
agent_up() { case "$(http_code "http://127.0.0.1:${AGENT_PORT}/runtime")" in 200 | 401) return 0 ;; *) return 1 ;; esac; }
# First boot creates the admin account; the UI is ready once it no longer asks for one.
ui_ready() { curl -sf --max-time 5 "http://127.0.0.1:${UI_PORT}/api/auth/bootstrap" | grep -q '"needsBootstrap":false'; }
stack_ready() { ui_ready && agent_up; }

# --- engine versions ---------------------------------------------------------------------------
# Tested: Podman 4.9, 5.x (5.6, 5.8) and 6.x (6.1); Docker 24 and newer. Keep in step with the
# "Supported versions" table in README.md and deploy/setup/tests/engine-matrix.sh.
PODMAN_OLDEST_TESTED="4.9"
DOCKER_OLDEST_TESTED="24"

version_major() { printf '%s' "${1%%.*}"; }
version_minor() { local rest="${1#*.}"; printf '%s' "${rest%%.*}"; }
is_number() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# engine_support ENGINE VERSION → "supported", "warn:<why>" or "refuse:<why>"
engine_support() {
  local engine="$1" version="$2" major minor
  major="$(version_major "${version}")"
  minor="$(version_minor "${version}")"
  is_number "${major}" || { echo "warn:couldn't read the ${engine} version (${version:-empty})"; return 0; }
  is_number "${minor}" || minor=0
  case "${engine}" in
    podman)
      if [ "${major}" -lt 4 ]; then
        echo "refuse:Podman ${version} is too old. Install Podman 5 or newer (4.9 is the oldest that works)."
      elif [ "${major}" -eq 4 ] && [ "${minor}" -lt 9 ]; then
        echo "warn:Podman ${version} is older than the oldest tested release (${PODMAN_OLDEST_TESTED}); if anything fails, update Podman."
      else
        echo supported
      fi
      ;;
    docker)
      if [ "${major}" -lt 20 ]; then
        echo "refuse:Docker ${version} is too old. Install Docker ${DOCKER_OLDEST_TESTED} or newer."
      elif [ "${major}" -lt "${DOCKER_OLDEST_TESTED}" ]; then
        echo "warn:Docker ${version} is older than the oldest tested release (${DOCKER_OLDEST_TESTED}); if anything fails, update Docker."
      else
        echo supported
      fi
      ;;
  esac
}

# podman_pair_support CLIENT SERVER → a podman command and a Podman machine of different major
# versions disagree on how ports are forwarded (containers start but are unreachable).
podman_pair_support() {
  local client="$1" server="$2"
  [ -n "${server}" ] || { echo supported; return 0; }
  if [ "$(version_major "${client}")" != "$(version_major "${server}")" ]; then
    echo "refuse:Your podman command is ${client} but the Podman machine runs ${server}. Use the same major version for both: update Podman, then recreate the machine (podman machine rm, podman machine init)."
  else
    echo supported
  fi
}

# apply_support "<engine_support output>" — prints the warning or stops the setup.
apply_support() {
  case "$1" in
    refuse:*) die "${1#refuse:}" ;;
    warn:*) warn "${1#warn:}" ;;
  esac
}

# --- engine checks -----------------------------------------------------------------------------
SOCKET_CANDIDATES=()
ENGINE_SOCKET=""
EXTRA_ARGS=()

check_docker() {
  command -v docker >/dev/null 2>&1 ||
    die "docker isn't installed. Install Docker Desktop (macOS/Windows) or Docker Engine (Linux), or use setup-podman.sh."
  docker info >/dev/null 2>&1 ||
    die "Docker is installed but not running. Start Docker Desktop (Linux: start the docker service) and re-run."
  local version
  version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
  apply_support "$(engine_support docker "${version}")"
  ok "Docker ${version} is running"
  SOCKET_CANDIDATES=(/var/run/docker.sock)
  # Rootless Docker Engine serves its API from the user's own socket instead.
  if docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    local host
    host="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
    case "${host}" in unix://*) SOCKET_CANDIDATES=("${host#unix://}" /var/run/docker.sock) ;; esac
  fi
}

# wait_for_socket PATH — up to 10 seconds for a just-started service to create its socket.
wait_for_socket() {
  local tries=0
  until [ -S "$1" ]; do
    tries=$((tries + 1))
    [ "${tries}" -gt 20 ] && return 1
    sleep 0.5
  done
}

podman_socket_path() {
  local path
  path="$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)"
  printf '%s' "${path#unix://}"
}

check_podman() {
  command -v podman >/dev/null 2>&1 ||
    die "podman isn't installed. macOS/Windows: install Podman Desktop and let it install Podman. Linux: install the podman package."
  local version
  version="$(podman --version | awk '{print $NF}')"
  apply_support "$(engine_support podman "${version}")"
  ok "podman ${version} installed"

  # macOS and Windows run containers inside a Podman machine (a Linux VM). The default machine is
  # rootless, and nothing here needs podman-mac-helper or any other admin-installed piece.
  if [ "${OS}" != Linux ]; then
    if [ -z "$(podman machine list --format '{{.Name}}' 2>/dev/null || true)" ]; then
      warn "No Podman machine exists yet."
      confirm "Create one now (podman machine init, a ~1 GB download)?" ||
        die "A Podman machine is required on ${OS}."
      podman machine init
    fi
    if ! podman machine list --format '{{.Running}}' 2>/dev/null | grep -q true; then
      echo "  Starting the Podman machine..."
      podman machine start >/dev/null
    fi
    ok "Podman machine is running"
  fi

  podman info >/dev/null 2>&1 || die "podman can't reach its engine: $(podman info 2>&1 | tail -1)"
  # The engine itself (inside the Podman machine on macOS/Windows) can be another release.
  local engine_version
  engine_version="$(podman info --format '{{.Version.Version}}' 2>/dev/null || true)"
  if [ -n "${engine_version}" ] && [ "${engine_version}" != "${version}" ]; then
    apply_support "$(engine_support podman "${engine_version}")"
    apply_support "$(podman_pair_support "${version}" "${engine_version}")"
    ok "Podman engine ${engine_version}"
  fi
  local rootless
  rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo unknown)"
  [ "${rootless}" = true ] && ok "Rootless mode: containers run as your own user"

  local path
  path="$(podman_socket_path)"
  # On Linux the API socket is a separate service. Rootless needs no sudo to start it. Look for
  # the socket file itself: Podman 5.x reports RemoteSocket.Exists=true even when nothing listens.
  if [ "${OS}" = Linux ] && [ -n "${path}" ] && [ ! -S "${path}" ]; then
    if [ "${rootless}" = true ]; then
      if systemctl --user enable --now podman.socket >/dev/null 2>&1 && wait_for_socket "${path}"; then
        ok "Started your user's Podman API socket (systemctl --user podman.socket)"
      else
        # No systemd user session: serve it from a background process.
        mkdir -p "$(dirname "${path}")"
        nohup podman system service --time=0 "unix://${path}" >/dev/null 2>&1 &
        if wait_for_socket "${path}"; then
          ok "Started a Podman API service in the background (it stops when you log out)"
        else
          warn "Couldn't start Podman's API socket at ${path}; build/test checks will run inside the container."
        fi
      fi
    else
      warn "Podman's API socket (${path}) isn't running and starting it needs root."
      warn "Ask an admin to run: systemctl enable --now podman.socket"
    fi
  fi
  [ -n "${path}" ] && ok "Podman API socket: ${path}"
  SOCKET_CANDIDATES=(/var/run/docker.sock)
  [ -n "${path}" ] && SOCKET_CANDIDATES+=("${path}")
  # SELinux (Fedora/RHEL) would block the container from the socket and your folders; this skips
  # relabelling rather than rewriting labels on your home directory.
  EXTRA_ARGS+=(--security-opt label=disable)
}

# The architecture containers run on, as the engine reports it (Podman: arm64/amd64, Docker:
# aarch64/x86_64). The shell's own `uname -m` can differ: a Rosetta terminal on Apple Silicon
# says x86_64, which would pull the amd64 image into an arm64 engine to run under emulation.
engine_arch() {
  if [ "${RUNTIME}" = podman ]; then
    podman info --format '{{.Host.Arch}}' 2>/dev/null || true
  else
    docker info --format '{{.Architecture}}' 2>/dev/null || true
  fi
}

image_tag() {
  local arch
  arch="$(engine_arch)"
  [ -n "${arch}" ] || arch="$(uname -m)"
  case "${arch}" in
    arm64 | aarch64) echo arm64 ;;
    x86_64 | amd64) echo amd64 ;;
    *) die "Unsupported CPU architecture: ${arch} (images exist for arm64 and amd64)." ;;
  esac
}

# wait_for "what" seconds command...
wait_for() {
  local what="$1" seconds="$2" waited=0
  shift 2
  printf '  Waiting for %s' "${what}"
  until "$@" >/dev/null 2>&1; do
    waited=$((waited + 2))
    if [ "${waited}" -ge "${seconds}" ]; then
      echo
      warn "${what} didn't come up within ${seconds}s. Last log lines:"
      rt logs --tail 30 "${CONTAINER}" 2>&1 | sed 's/^/    /'
      die "${what} failed to start."
    fi
    printf '.'
    sleep 2
  done
  echo
  ok "${what} is up"
}

# Socket paths are as seen where containers run (inside the VM for Docker Desktop and Podman
# machines), so the only reliable test is a throwaway container from the image (it ships the
# docker CLI) talking to the engine through each candidate.
choose_socket() {
  local image="$1" sock out
  for sock in "${SOCKET_CANDIDATES[@]}"; do
    if out="$(rt run --rm --entrypoint docker ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
      -v "${sock}:/var/run/docker.sock" "${image}" \
      version --format '{{.Server.Version}}' 2>&1)"; then
      ENGINE_SOCKET="${sock}"
      ok "${sock} works (engine $(printf '%s' "${out}" | tail -1))"
      return 0
    fi
    warn "${sock} doesn't work: $(printf '%s' "${out}" | tail -1)"
  done
  return 1
}

verify_engine_from_agent() {
  local out
  if out="$(rt exec "${CONTAINER}" docker version --format '{{.Server.Version}}' 2>&1)"; then
    ok "The agent reaches the ${RUNTIME} engine (${out}): build/test checks run in toolchain containers"
    return 0
  fi
  warn "The agent can't reach the ${RUNTIME} engine: $(printf '%s' "${out}" | tail -1)"
  return 1
}

# --- actions -----------------------------------------------------------------------------------
action_status() {
  load_state
  UI_PORT="${UI_PORT:-3000}"
  AGENT_PORT="${AGENT_PORT:-3400}"
  step "Fluxline (${RUNTIME})"
  if [ "${RUNTIME}" = podman ]; then
    echo "  podman $(podman --version | awk '{print $NF}'), engine $(podman info --format '{{.Version.Version}}' 2>/dev/null || echo unreachable)"
  else
    echo "  Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unreachable)"
  fi
  if ! exists "${CONTAINER}"; then
    warn "No ${CONTAINER} container. Start it with: ${SELF}"
    return 0
  fi
  rt ps -a --filter "name=^${CONTAINER}\$" --format '{{.Names}}  {{.Status}}  {{.Ports}}' | sed 's/^/  /'
  local restarts
  restarts="$(rt inspect "${CONTAINER}" --format '{{.RestartCount}}' 2>/dev/null || echo 0)"
  if [ "${restarts:-0}" != 0 ]; then
    warn "${CONTAINER} has restarted ${restarts} time(s). Its last log lines:"
    rt logs --tail 15 "${CONTAINER}" 2>&1 | sed 's/^/    /'
  fi
  if agent_up; then ok "Agent API answers on :${AGENT_PORT}"; else warn "Agent API isn't answering on :${AGENT_PORT}"; fi
  if [ -z "${REMOTE_UI_URL:-}" ]; then
    if [ "$(http_code "http://127.0.0.1:${UI_PORT}/health")" = 200 ]; then
      ok "UI answers on http://localhost:${UI_PORT}"
    else
      warn "UI isn't answering on :${UI_PORT}"
    fi
  fi
  if rt exec "${CONTAINER}" test -S /var/run/docker.sock 2>/dev/null; then
    verify_engine_from_agent || true
  else
    warn "No engine socket in the container: build/test checks run inside it"
  fi
}

action_down() {
  if [ "${CLEAN}" = 1 ]; then
    clean_everything
    echo
    echo "  Everything is removed. Start fresh with: ${SELF}"
    return 0
  fi
  stop_running
  echo
  echo "  Data is kept in the ${DATA_VOLUME} and ${PG_VOLUME} volumes, and the login in"
  echo "  ${STATE_FILE}. Start again with: ${SELF}"
  echo "  To wipe everything (data, saved keys, login): ${SELF} down --clean"
}

# Fluxline's container and the earlier setup's three (Postgres, agent, UI on the same ports).
fluxline_containers() {
  local name
  for name in "${CONTAINER}" ${LEGACY_CONTAINERS}; do
    if exists "${name}"; then echo "${name}"; fi
  done
}

# Stops and removes every Fluxline container still around, so ports and names are free. Volumes
# (the data) stay unless --clean.
stop_running() {
  local names
  names="$(fluxline_containers | tr '\n' ' ')"
  [ -n "${names// /}" ] || return 0
  step "Stopping the running Fluxline"
  local name
  for name in ${names}; do
    rt rm -f "${name}" >/dev/null 2>&1 && ok "stopped and removed ${name}"
  done
  case " ${names} " in
    *" ${NAME}-agent "* | *" ${NAME}-ui "* | *" ${NAME}-db "*)
      [ "${CLEAN}" = 1 ] ||
        warn "That was the earlier three-container setup; its data stays in ${NAME}-db-data and ${NAME}-agent-data (--clean removes them)."
      ;;
  esac
  rt network rm "${NAME}-net" >/dev/null 2>&1 || true
}

# --clean: everything this script created, so the next start is a first start. Never touches the
# code folder, ~/fluxline-repos or the VS Code bridge settings (~/.ai-sdlc).
clean_everything() {
  local volumes=() volume
  for volume in "${DATA_VOLUME}" "${PG_VOLUME}" "${NAME}-db-data" "${NAME}-agent-data"; do
    if rt volume inspect "${volume}" >/dev/null 2>&1; then volumes+=("${volume}"); fi
  done
  step "Clean start: removing all Fluxline data"
  echo "  This deletes:"
  echo "    - containers: $(fluxline_containers | tr '\n' ' ' | sed 's/ *$//' | sed 's/^$/(none running)/')"
  echo "    - volumes: ${volumes[*]:-(none)}  (tasks, workspaces, users, saved API keys and Git credentials)"
  echo "    - saved answers and admin login: ${STATE_FILE}"
  echo "    - task working copies: ${STATE_DIR}/runs"
  echo "  Your code folder, ~/fluxline-repos and VS Code settings are not touched."
  confirm_destructive "Delete all of this?" || die "Nothing was deleted."
  stop_running
  for volume in ${volumes[@]+"${volumes[@]}"}; do
    rt volume rm -f "${volume}" >/dev/null 2>&1 && ok "removed volume ${volume}"
  done
  rm -f "${STATE_FILE}" && ok "removed ${STATE_FILE}"
  if [ -d "${STATE_DIR}/runs" ]; then rm -rf "${STATE_DIR}/runs" && ok "removed ${STATE_DIR}/runs"; fi
}

start_container() {
  local image="$1" origins="http://localhost:${UI_PORT},http://127.0.0.1:${UI_PORT}"
  step "Starting Fluxline"
  if exists "${CONTAINER}"; then rt rm -f "${CONTAINER}" >/dev/null; fi
  local args=(
    -d --name "${CONTAINER}" --restart unless-stopped
    -p "${AGENT_PORT}:3400"
    -v "${DATA_VOLUME}:/data"
  )
  if [ -n "${REMOTE_UI_URL}" ]; then
    # Agent only. The hosted UI's page calls this agent from the browser, so its origin must be
    # allowed too.
    origins="${origins},$(printf '%s' "${REMOTE_UI_URL}" | sed -E 's#^(https?://[^/]+).*#\1#')"
    args+=(
      -e FLUXLINE_MODE=agent -e AI_SDLC_REMOTE_UI_URL="${REMOTE_UI_URL}"
      -e AI_SDLC_AGENT_TOKEN -e AI_SDLC_API_TOKEN
    )
  else
    # LOCAL_DEV (entrypoint default): served over plain http://localhost, so the session cookie
    # isn't marked Secure. ADMIN_* are used on first boot only.
    args+=(
      -p "${UI_PORT}:3000"
      -v "${PG_VOLUME}:/var/lib/postgresql/data"
      -e ADMIN_EMAIL -e ADMIN_PASSWORD
      -e AGENT_PUBLIC_URL="http://localhost:${AGENT_PORT}"
    )
  fi
  args+=(-e AI_SDLC_ALLOWED_ORIGINS="${origins}")
  if [ "${WORKSPACE}" != - ]; then
    # Same path inside and out, so paths in the UI and the task logs match your machine.
    args+=(-v "${WORKSPACE}:${WORKSPACE}" -e AI_SDLC_WORKSPACE_ROOT="${WORKSPACE}")
  fi
  mkdir -p "${HOME}/fluxline-repos"
  args+=(-v "${HOME}/fluxline-repos:/repos")
  # Task working copies live here, at the same path inside and out, so VS Code (the bridge runs
  # on this machine) can edit them; under the data volume it would see paths that don't exist.
  mkdir -p "${STATE_DIR}/runs"
  args+=(-v "${STATE_DIR}/runs:${STATE_DIR}/runs" -e AI_SDLC_RUN_ROOT="${STATE_DIR}/runs")
  if [ -f "${HOME}/.gitconfig" ]; then args+=(-v "${HOME}/.gitconfig:/root/.gitconfig:ro"); fi
  if [ -d "${HOME}/.ssh" ]; then args+=(-v "${HOME}/.ssh:/root/.ssh:ro"); fi
  if [ -d "${HOME}/.codex" ]; then args+=(-v "${HOME}/.codex:/root/.codex"); fi
  # The VS Code bridge publishes its port, token and socket here; the agent finds it on its own.
  mkdir -p "${HOME}/.ai-sdlc"
  args+=(-v "${HOME}/.ai-sdlc:/root/.ai-sdlc")
  # Docker Engine on Linux has no host.docker.internal unless asked; Desktop and Podman do.
  if [ "${RUNTIME}" = docker ] && [ "${OS}" = Linux ]; then
    args+=(--add-host=host.docker.internal:host-gateway)
  fi
  # `-e NAME` with no value: the engine reads it from this process's environment, so secrets never
  # show up in the process list.
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then args+=(-e ANTHROPIC_API_KEY); fi
  if [ -n "${OPENAI_API_KEY:-}" ]; then args+=(-e OPENAI_API_KEY); fi
  if [ -n "${ENGINE_SOCKET}" ]; then
    args+=(-v "${ENGINE_SOCKET}:/var/run/docker.sock" -e AI_SDLC_CONTAINER_ID="${CONTAINER}")
  fi
  if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then args+=("${EXTRA_ARGS[@]}"); fi
  if [ "${FLUXLINE_DEBUG:-}" = 1 ]; then
    # Secrets are passed as bare `-e NAME`, so this prints no values.
    printf '  %s' "${RUNTIME} run"; printf ' %q' "${args[@]}" "${image}"; echo
  fi
  ADMIN_EMAIL="${ADMIN_EMAIL}" ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
    AI_SDLC_API_TOKEN="${AGENT_API_TOKEN}" AI_SDLC_AGENT_TOKEN="${REMOTE_AGENT_TOKEN:-}" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    rt run "${args[@]}" "${image}" >/dev/null
  if [ -n "${REMOTE_UI_URL}" ]; then
    wait_for "Agent API" 120 agent_up
  else
    # First boot initialises Postgres, applies the schema and creates the admin account.
    wait_for "Fluxline" 240 stack_ready
  fi
}

find_code_cli() {
  local candidate
  for candidate in code \
    "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
    "${HOME}/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      printf '%s' "$(command -v "${candidate}")"
      return 0
    fi
  done
  return 1
}

# The extension is served by the UI, so it always matches the deployed version.
install_vscode_bridge() {
  local ui_base="$1" vsix_url code dir
  vsix_url="${ui_base}/downloads/ai-sdlc-vscode-bridge-latest.vsix"
  step "VS Code bridge extension"
  if ! code="$(find_code_cli)"; then
    warn "VS Code's \`code\` command wasn't found. To use the VS Code provider, install the extension"
    warn "from ${vsix_url} (Extensions view → … → Install from VSIX)."
    return 0
  fi
  dir="$(mktemp -d)"
  if ! curl -sfL -o "${dir}/ai-sdlc-vscode-bridge.vsix" "${vsix_url}"; then
    warn "Couldn't download ${vsix_url}; install the extension from there later."
    rm -rf "${dir}"
    return 0
  fi
  if "${code}" --install-extension "${dir}/ai-sdlc-vscode-bridge.vsix" --force >/dev/null 2>&1; then
    ok "Installed in VS Code. Reload open VS Code windows once; the agent connects by itself."
  else
    warn "VS Code didn't accept the extension; install ${vsix_url} from the Extensions view."
  fi
  rm -rf "${dir}"
}

action_up() {
  printf '%sFluxline setup (%s)%s\n%s© 2026 Shantanu Sune · For developers, by developers%s\n' \
    "${BOLD}" "${RUNTIME}" "${RESET}" "${DIM}" "${RESET}"
  command -v curl >/dev/null 2>&1 || die "curl is required."

  step "Checking ${RUNTIME}"
  "check_${RUNTIME}"
  local image
  image="${FLUXLINE_IMAGE:-${REGISTRY}/fluxline-standalone:$(image_tag)}"

  if [ "${CLEAN}" = 1 ]; then clean_everything; fi
  load_state
  [ -n "${CLI_REMOTE_UI_URL}" ] && REMOTE_UI_URL="${CLI_REMOTE_UI_URL%/}"
  REMOTE_UI_URL="${REMOTE_UI_URL:-}"
  UI_PORT="${UI_PORT:-3000}"
  AGENT_PORT="${AGENT_PORT:-3400}"
  ADMIN_EMAIL="${ADMIN_EMAIL:-admin@localhost.com}"

  step "Two quick questions (Enter accepts the [default])"
  local default_workspace=-
  if git -C "${PWD}" rev-parse --show-toplevel >/dev/null 2>&1; then
    default_workspace="$(git -C "${PWD}" rev-parse --show-toplevel)"
  elif [ -d "${HOME}/code" ]; then
    default_workspace="${HOME}/code"
  fi
  ask WORKSPACE "Folder with your code, a repo or a folder of repos (- for none)" "${default_workspace}"
  if [ -z "${WORKSPACE}" ] || [ "${WORKSPACE}" = - ]; then
    WORKSPACE=-
  else
    WORKSPACE="${WORKSPACE/#\~/$HOME}"
    [ -d "${WORKSPACE}" ] || die "Folder not found: ${WORKSPACE}"
    WORKSPACE="$(cd "${WORKSPACE}" && pwd)"
    if [ "${RUNTIME}" = podman ] && [ "${OS}" != Linux ]; then
      case "${WORKSPACE}" in
        "${HOME}"/*) ;;
        *) warn "The Podman machine only shares your home folder by default; ${WORKSPACE} may look empty to the agent." ;;
      esac
    fi
  fi
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    ask_secret ANTHROPIC_API_KEY "Anthropic API key for the Claude provider (Enter to skip; VS Code needs none)"
  fi
  if [ -n "${REMOTE_UI_URL}" ]; then
    case "${REMOTE_UI_URL}" in http://* | https://*) ;; *) die "--remote needs an http:// or https:// address." ;; esac
    if [ -z "${REMOTE_AGENT_TOKEN:-}" ]; then
      echo "  Linking to ${REMOTE_UI_URL}: create a token there under Account → Agent tokens."
      ask_secret REMOTE_AGENT_TOKEN "Personal access token"
    fi
    [ -n "${REMOTE_AGENT_TOKEN:-}" ] || die "A personal access token is required to link to ${REMOTE_UI_URL}."
  fi

  # The admin account is created from these on the first start only; an existing data volume keeps
  # the account it already has.
  local existing_data=0
  rt volume inspect "${DATA_VOLUME}" >/dev/null 2>&1 && existing_data=1
  if [ -z "${ADMIN_PASSWORD:-}" ] && [ "${existing_data}" = 1 ] && [ -z "${REMOTE_UI_URL}" ]; then
    warn "${DATA_VOLUME} already has an account, and its password isn't in ${STATE_FILE}."
    warn "Sign in with the password you chose then, or start fresh: ${RUNTIME} volume rm ${DATA_VOLUME} ${PG_VOLUME}"
  fi
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(random_token 16)}"
  [ "${#ADMIN_PASSWORD}" -ge 8 ] || die "ADMIN_PASSWORD must be at least 8 characters."
  # Only used in agent-only mode, where the hosted UI needs it to call this agent.
  AGENT_API_TOKEN="${AGENT_API_TOKEN:-fl-$(random_token 32)}"
  save_state

  step "Pulling the image"
  # FLUXLINE_PULL=0: use an image already on this machine (e.g. built locally to test before publishing).
  if [ "${FLUXLINE_PULL:-1}" = 0 ] && rt image inspect "${image}" >/dev/null 2>&1; then
    echo "  ${image} (local)"
  else
    echo "  ${image} (about 1.3 GB the first time; updates download only what changed)"
    # In a terminal, show the engine's own per-layer progress bars; in a log, stay quiet.
    if [ -t 1 ]; then
      rt pull "${image}" ||
        die "Couldn't pull ${image}. To pull from a mirror, set FLUXLINE_REGISTRY and re-run."
    else
      rt pull -q "${image}" >/dev/null ||
        die "Couldn't pull ${image}. To pull from a mirror, set FLUXLINE_REGISTRY and re-run."
    fi
  fi
  ok "Image ready"

  if [ "${FLUXLINE_TOOLCHAIN:-1}" != 0 ]; then
    step "Checking which ${RUNTIME} socket the agent can use for build/test containers"
    choose_socket "${image}" ||
      warn "None did, so build/test checks will run inside the Fluxline container instead."
  fi

  stop_running
  start_container "${image}"
  local engine_ok=1
  if [ -n "${ENGINE_SOCKET}" ]; then verify_engine_from_agent || engine_ok=0; fi

  if [ "${FLUXLINE_VSCODE:-1}" != 0 ]; then
    install_vscode_bridge "$([ -n "${REMOTE_UI_URL}" ] && echo "${REMOTE_UI_URL}" || echo "http://127.0.0.1:${UI_PORT}")"
  fi

  step "Ready"
  if [ -z "${REMOTE_UI_URL}" ]; then
    echo "  Open:         ${BOLD}http://localhost:${UI_PORT}${RESET}"
    echo "  Sign in:      ${ADMIN_EMAIL}  /  ${ADMIN_PASSWORD}"
  else
    echo "  Open:         ${BOLD}${REMOTE_UI_URL}${RESET}, then Control plane → add http://localhost:${AGENT_PORT}"
    echo "  Agent token:  ${AGENT_API_TOKEN}"
  fi
  echo "  Coding agent: VS Code$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo ", Claude")$({ [ -n "${OPENAI_API_KEY:-}" ] || [ -f "${HOME}/.codex/auth.json" ]; } && echo ", Codex") (pick one in + New change)"
  echo "  Checks run:   $([ -n "${ENGINE_SOCKET}" ] && [ "${engine_ok}" = 1 ] && echo "in toolchain containers" || echo "inside the Fluxline container")"
  echo "  Saved in:     ${STATE_FILE}"
  echo "  ${DIM}Status: ${SELF} status   Logs: ${RUNTIME} logs -f ${CONTAINER}   Stop: ${SELF} down${RESET}"
}

[ "${FLUXLINE_SETUP_LIB:-}" = 1 ] || "action_${ACTION}"
