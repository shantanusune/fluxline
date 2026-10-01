#!/usr/bin/env bash
# Fluxline setup wizard: starts the whole stack (Postgres + agent + UI) from the published images on
# Docker or Podman. Asks two things: your code folder and, optionally, an Anthropic API key.
# Everything else is generated or detected. Needs no admin rights: rootless Podman is the target.
#
#   ./setup-podman.sh                     # or ./setup-docker.sh
#   ./setup-podman.sh --yes               # no questions at all
#   ./setup-podman.sh --remote https://fluxline.yourco.com
#                                                      # agent only, linked to a hosted UI
#   ./setup-podman.sh status              # what's running; can the agent reach the engine
#   ./setup-podman.sh down                # remove the containers (data is kept)
#
# Optional environment variables:
#   FLUXLINE_REGISTRY   where the Fluxline images come from (default docker.io/suneshantanu), for a
#                       corporate mirror; DB_IMAGE likewise for Postgres
#   UI_PORT, AGENT_PORT host ports (default 3000, 3400)
#   ADMIN_EMAIL, ADMIN_PASSWORD, OPENAI_API_KEY, FLUXLINE_TOOLCHAIN=0 (never mount the engine socket),
#   FLUXLINE_VSCODE=0   don't install the VS Code bridge extension
#   FLUXLINE_NAME       prefix for containers, network and volumes (default fluxline), e.g. to run a
#                       second, separate stack; FLUXLINE_HOME moves the saved answers
#
# VS Code: when the `code` CLI is found, the bridge extension is installed from the UI. The agent
# finds the bridge by itself (connection_mode: auto — the bridge's socket on Linux, the host gateway
# on macOS/Windows) through the host's ~/.ai-sdlc mounted into it; nothing to configure.
#
# Answers, the generated database password, admin password and agent token are saved in
# ~/.fluxline/setup.env (mode 600), so re-running keeps the same data and logins.
#
# Engine socket: the agent runs build/test checks in sibling toolchain containers through the
# `docker` CLI, which needs the engine's API socket mounted at /var/run/docker.sock. Under Podman
# that socket lives elsewhere (on macOS, inside the Podman machine VM), so the wizard tries
# /var/run/docker.sock first, then Podman's own socket, and keeps whichever a test container can
# actually use. Under rootless Podman this grants nothing beyond what your own user already has.
set -euo pipefail

RUNTIME="${1:-}"
shift || true
case "${RUNTIME}" in
  docker | podman) ;;
  *)
    echo "Usage: $0 <docker|podman> [up|status|down] [--yes] [--remote <ui-url>]" >&2
    exit 2
    ;;
esac

ACTION=up
ASSUME_YES=0
CLI_REMOTE_UI_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    up | status | down) ACTION="$1" ;;
    -y | --yes) ASSUME_YES=1 ;;
    --remote)
      [ $# -ge 2 ] || { echo "--remote needs the hosted UI's address" >&2; exit 2; }
      CLI_REMOTE_UI_URL="$2"
      shift
      ;;
    -h | --help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
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
DB_IMAGE="${DB_IMAGE:-docker.io/library/postgres:17-alpine}"
NAME="${FLUXLINE_NAME:-fluxline}"
NETWORK="${NAME}-net"
DB_CONTAINER="${NAME}-db"
AGENT_CONTAINER="${NAME}-agent"
UI_CONTAINER="${NAME}-ui"
DB_VOLUME="${NAME}-db-data"
AGENT_VOLUME="${NAME}-agent-data"
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

random_token() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}" || true; }
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
rt() { "${RUNTIME}" "$@"; }
exists() { rt container inspect "$1" >/dev/null 2>&1; }

STATE_KEYS="REMOTE_UI_URL REMOTE_AGENT_TOKEN WORKSPACE ADMIN_EMAIL ADMIN_PASSWORD AGENT_API_TOKEN
  DB_PASSWORD ANTHROPIC_API_KEY OPENAI_API_KEY UI_PORT AGENT_PORT CONNECTION_CREATED"

save_state() {
  mkdir -p "${STATE_DIR}"
  (
    umask 077
    echo "# Written by fluxline-setup.sh. Keep it: the database was initialised with DB_PASSWORD."
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
    [ -n "${!key:-}" ] && continue # environment variables win over saved answers
    eval "${line}"
  done <"${STATE_FILE}"
}

# --- engine checks -----------------------------------------------------------------------------
SOCKET_CANDIDATES=()
ENGINE_SOCKET=""
EXTRA_AGENT_ARGS=()

check_docker() {
  command -v docker >/dev/null 2>&1 ||
    die "docker isn't installed. Install Docker Desktop (macOS/Windows) or Docker Engine (Linux), or use setup-podman.sh."
  docker info >/dev/null 2>&1 ||
    die "Docker is installed but not running. Start Docker Desktop (Linux: start the docker service) and re-run."
  ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) is running"
  SOCKET_CANDIDATES=(/var/run/docker.sock)
  # Rootless Docker Engine serves its API from the user's own socket instead.
  if docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    local host
    host="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
    case "${host}" in unix://*) SOCKET_CANDIDATES=("${host#unix://}" /var/run/docker.sock) ;; esac
  fi
}

podman_socket_path() {
  local path
  path="$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)"
  printf '%s' "${path#unix://}"
}

check_podman() {
  command -v podman >/dev/null 2>&1 ||
    die "podman isn't installed. macOS/Windows: install Podman Desktop and let it install Podman (no admin rights needed for a rootless machine). Linux: ask for the podman package."
  local version
  version="$(podman --version | awk '{print $NF}')"
  case "${version}" in [0-3].*) die "Podman ${version} is too old; 4.0 or newer is needed." ;; esac
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
  local rootless
  rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo unknown)"
  [ "${rootless}" = true ] && ok "Rootless mode: containers run as your own user"

  local path
  path="$(podman_socket_path)"
  # On Linux the API socket is a separate service. Rootless needs no sudo to start it.
  if [ "${OS}" = Linux ] && [ "$(podman info --format '{{.Host.RemoteSocket.Exists}}' 2>/dev/null)" != true ]; then
    if [ "${rootless}" = true ]; then
      if systemctl --user enable --now podman.socket >/dev/null 2>&1; then
        ok "Started your user's Podman API socket (systemctl --user podman.socket)"
      else
        # No systemd user session (common on locked-down hosts): serve it from a background process.
        mkdir -p "$(dirname "${path}")"
        nohup podman system service --time=0 "unix://${path}" >/dev/null 2>&1 &
        sleep 1
        ok "Started a Podman API service in the background (it stops when you log out)"
      fi
    else
      warn "Podman's API socket (${path}) isn't running and starting it needs root."
      warn "Ask an admin to run: systemctl enable --now podman.socket"
    fi
  fi
  [ -n "${path}" ] && ok "Podman API socket: ${path}"
  SOCKET_CANDIDATES=(/var/run/docker.sock)
  [ -n "${path}" ] && SOCKET_CANDIDATES+=("${path}")
  # SELinux (Fedora/RHEL) would block the agent from the socket and your folders; this skips
  # relabelling rather than rewriting labels on your home directory.
  EXTRA_AGENT_ARGS+=(--security-opt label=disable)
}

image_tag() {
  case "$(uname -m)" in
    arm64 | aarch64) echo arm64 ;;
    x86_64 | amd64) echo amd64 ;;
    *) die "Unsupported CPU architecture: $(uname -m) (images exist for arm64 and amd64)." ;;
  esac
}

# wait_for "what" seconds container command...
wait_for() {
  local what="$1" seconds="$2" container="$3" waited=0
  shift 3
  printf '  Waiting for %s' "${what}"
  until "$@" >/dev/null 2>&1; do
    waited=$((waited + 2))
    if [ "${waited}" -ge "${seconds}" ]; then
      echo
      warn "${what} didn't come up within ${seconds}s. Last log lines from ${container}:"
      rt logs --tail 30 "${container}" 2>&1 | sed 's/^/    /'
      die "${what} failed to start."
    fi
    printf '.'
    sleep 2
  done
  echo
  ok "${what} is up"
}

# Socket paths are as seen where containers run (inside the VM for Docker Desktop and Podman
# machines), so the only reliable test is a throwaway container from the agent image (it ships the
# docker CLI) talking to the engine through each candidate.
choose_socket() {
  local image="$1" sock out
  for sock in "${SOCKET_CANDIDATES[@]}"; do
    if out="$(rt run --rm ${EXTRA_AGENT_ARGS[@]+"${EXTRA_AGENT_ARGS[@]}"} \
      -v "${sock}:/var/run/docker.sock" "${image}" \
      docker version --format '{{.Server.Version}}' 2>&1)"; then
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
  if out="$(rt exec "${AGENT_CONTAINER}" docker version --format '{{.Server.Version}}' 2>&1)"; then
    ok "The agent reaches the ${RUNTIME} engine (${out}): build/test checks run in toolchain containers"
    return 0
  fi
  warn "The agent can't reach the ${RUNTIME} engine: $(printf '%s' "${out}" | tail -1)"
  return 1
}

# --- actions -----------------------------------------------------------------------------------
action_status() {
  load_state
  step "Fluxline containers (${RUNTIME})"
  rt ps -a --filter "name=${NAME}-" --format '{{.Names}}  {{.Status}}  {{.Ports}}' | sed 's/^/  /'
  if exists "${AGENT_CONTAINER}"; then
    if curl -sf -o /dev/null -H "Authorization: Bearer ${AGENT_API_TOKEN:-}" \
      "http://127.0.0.1:${AGENT_PORT:-3400}/runtime"; then
      ok "Agent API answers on :${AGENT_PORT:-3400}"
    else
      warn "Agent API isn't answering on :${AGENT_PORT:-3400}"
    fi
    if rt exec "${AGENT_CONTAINER}" test -S /var/run/docker.sock 2>/dev/null; then
      verify_engine_from_agent || true
    else
      warn "No engine socket in the agent: build/test checks run in the agent's own shell"
    fi
  fi
  if exists "${UI_CONTAINER}"; then
    if curl -sf -o /dev/null "http://127.0.0.1:${UI_PORT:-3000}/health"; then
      ok "UI answers on http://localhost:${UI_PORT:-3000}"
    else
      warn "UI isn't answering on :${UI_PORT:-3000}"
    fi
  fi
}

action_down() {
  step "Removing Fluxline containers (${RUNTIME})"
  local name
  for name in "${UI_CONTAINER}" "${AGENT_CONTAINER}" "${DB_CONTAINER}"; do
    if exists "${name}"; then rt rm -f "${name}" >/dev/null && ok "removed ${name}"; fi
  done
  echo
  echo "  Data is kept in the ${DB_VOLUME} and ${AGENT_VOLUME} volumes, and the logins in"
  echo "  ${STATE_FILE}. Start again with: ${SELF}"
  echo "  To wipe everything: ${RUNTIME} volume rm ${DB_VOLUME} ${AGENT_VOLUME} && rm ${STATE_FILE}"
}

start_db() {
  step "Starting Postgres"
  rt network inspect "${NETWORK}" >/dev/null 2>&1 || rt network create "${NETWORK}" >/dev/null
  if exists "${DB_CONTAINER}"; then rt rm -f "${DB_CONTAINER}" >/dev/null; fi
  rt run -d --name "${DB_CONTAINER}" --network "${NETWORK}" --restart unless-stopped \
    -e POSTGRES_USER=fluxline -e POSTGRES_PASSWORD="${DB_PASSWORD}" -e POSTGRES_DB=fluxline \
    -v "${DB_VOLUME}:/var/lib/postgresql/data" \
    "${DB_IMAGE}" postgres -c max_connections=150 >/dev/null
  wait_for "Postgres" 60 "${DB_CONTAINER}" rt exec "${DB_CONTAINER}" pg_isready -U fluxline -d fluxline
}

start_agent() {
  local image="$1" db_url="$2" origins="http://localhost:${UI_PORT},http://127.0.0.1:${UI_PORT}"
  step "Starting the agent"
  if exists "${AGENT_CONTAINER}"; then rt rm -f "${AGENT_CONTAINER}" >/dev/null; fi
  local args=(
    -d --name "${AGENT_CONTAINER}" --restart unless-stopped
    -p "${AGENT_PORT}:3400"
    -v "${AGENT_VOLUME}:/data"
    -e AI_SDLC_API_TOKEN
  )
  if [ -n "${REMOTE_UI_URL}" ]; then
    # The hosted UI's page calls this agent from the browser, so its origin must be allowed too.
    origins="${origins},$(printf '%s' "${REMOTE_UI_URL}" | sed -E 's#^(https?://[^/]+).*#\1#')"
    args+=(-e AI_SDLC_REMOTE_UI_URL="${REMOTE_UI_URL}" -e AI_SDLC_AGENT_TOKEN)
  else
    args+=(--network "${NETWORK}" -e AI_SDLC_DATABASE_URL="${db_url}" -e AI_SDLC_CHECKPOINTER=postgres)
  fi
  args+=(-e AI_SDLC_ALLOWED_ORIGINS="${origins}")
  if [ "${WORKSPACE}" != - ]; then
    # Same path inside and out, so paths in the UI and the task logs match your machine.
    args+=(-v "${WORKSPACE}:${WORKSPACE}" -e AI_SDLC_WORKSPACE_ROOT="${WORKSPACE}")
  fi
  mkdir -p "${HOME}/fluxline-repos"
  args+=(-v "${HOME}/fluxline-repos:/repos")
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
    args+=(-v "${ENGINE_SOCKET}:/var/run/docker.sock" -e AI_SDLC_CONTAINER_ID="${AGENT_CONTAINER}")
  fi
  if [ "${#EXTRA_AGENT_ARGS[@]}" -gt 0 ]; then args+=("${EXTRA_AGENT_ARGS[@]}"); fi
  AI_SDLC_API_TOKEN="${AGENT_API_TOKEN}" AI_SDLC_AGENT_TOKEN="${REMOTE_AGENT_TOKEN:-}" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    rt run "${args[@]}" "${image}" >/dev/null
  wait_for "Agent API" 120 "${AGENT_CONTAINER}" \
    curl -sf -H "Authorization: Bearer ${AGENT_API_TOKEN}" "http://127.0.0.1:${AGENT_PORT}/runtime"
}

start_ui() {
  local image="$1" db_url="$2"
  step "Starting the UI"
  if exists "${UI_CONTAINER}"; then rt rm -f "${UI_CONTAINER}" >/dev/null; fi
  # LOCAL_DEV=true: served over plain http://localhost, so the session cookie must not be marked
  # Secure (Safari would drop it).
  rt run -d --name "${UI_CONTAINER}" --network "${NETWORK}" --restart unless-stopped \
    -p "${UI_PORT}:3000" -e DATABASE_URL="${db_url}" -e LOCAL_DEV=true \
    "${image}" >/dev/null
  wait_for "UI" 120 "${UI_CONTAINER}" curl -sf "http://127.0.0.1:${UI_PORT}/api/auth/bootstrap"
}

# First run only: the admin account and the UI's connection to the agent, through the UI's own API.
bootstrap_ui() {
  local base="http://127.0.0.1:${UI_PORT}"
  if ! curl -sf "${base}/api/auth/bootstrap" | grep -q '"needsBootstrap":true'; then
    if [ "${CONNECTION_CREATED:-}" = 1 ]; then
      ok "Admin account and agent connection already set up"
    else
      warn "An account already exists, so nothing was created. Sign in, open Control plane and"
      warn "add http://localhost:${AGENT_PORT} with the agent token shown below."
    fi
    return 0
  fi
  COOKIE_JAR="$(mktemp)"
  trap 'rm -f "${COOKIE_JAR:-}"' EXIT
  curl -sf -c "${COOKIE_JAR}" -o /dev/null -X POST "${base}/api/auth/bootstrap" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$(json_escape "${ADMIN_EMAIL}")\",\"password\":\"$(json_escape "${ADMIN_PASSWORD}")\"}" ||
    die "Creating the admin account failed (see: ${RUNTIME} logs ${UI_CONTAINER})."
  ok "Admin account ${ADMIN_EMAIL} created"
  curl -sf -b "${COOKIE_JAR}" -o /dev/null -X POST "${base}/api/connections" \
    -H 'Content-Type: application/json' \
    -d "{\"label\":\"Local agent\",\"apiBase\":\"http://localhost:${AGENT_PORT}\",\"apiToken\":\"${AGENT_API_TOKEN}\"}" ||
    die "Creating the agent connection failed (see: ${RUNTIME} logs ${UI_CONTAINER})."
  CONNECTION_CREATED=1
  save_state
  ok "UI connected to the agent at http://localhost:${AGENT_PORT}"
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
  printf '%sFluxline setup (%s)%s\n' "${BOLD}" "${RUNTIME}" "${RESET}"
  command -v curl >/dev/null 2>&1 || die "curl is required."

  step "Checking ${RUNTIME}"
  "check_${RUNTIME}"
  local tag agent_image ui_image
  tag="$(image_tag)"
  agent_image="${REGISTRY}/fluxline-agent:${tag}"
  ui_image="${REGISTRY}/fluxline-ui:${tag}"

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

  # Generated once and reused: the database volume is initialised with this password.
  if [ -z "${REMOTE_UI_URL}" ] && [ -z "${DB_PASSWORD:-}" ]; then
    if rt volume inspect "${DB_VOLUME}" >/dev/null 2>&1; then
      die "The ${DB_VOLUME} volume exists but its password isn't in ${STATE_FILE}. Re-run with DB_PASSWORD=<it>, or start fresh: ${RUNTIME} volume rm ${DB_VOLUME}"
    fi
    DB_PASSWORD="$(random_token 24)"
  fi
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(random_token 16)}"
  [ "${#ADMIN_PASSWORD}" -ge 8 ] || die "ADMIN_PASSWORD must be at least 8 characters."
  AGENT_API_TOKEN="${AGENT_API_TOKEN:-fl-$(random_token 32)}"
  save_state

  step "Pulling images"
  local images=("${agent_image}") image
  [ -z "${REMOTE_UI_URL}" ] && images+=("${ui_image}" "${DB_IMAGE}")
  for image in "${images[@]}"; do
    echo "  ${image}"
    rt pull -q "${image}" >/dev/null ||
      die "Couldn't pull ${image}. Behind a corporate proxy or mirror? Set FLUXLINE_REGISTRY (and DB_IMAGE) and re-run."
  done
  ok "Images ready"

  if [ "${FLUXLINE_TOOLCHAIN:-1}" != 0 ]; then
    step "Checking which ${RUNTIME} socket the agent can use for build/test containers"
    choose_socket "${agent_image}" ||
      warn "None did, so build/test checks will run inside the agent's own container instead."
  fi

  local db_url="postgresql://fluxline:${DB_PASSWORD:-}@${DB_CONTAINER}:5432/fluxline"
  if [ -z "${REMOTE_UI_URL}" ]; then start_db; fi
  start_agent "${agent_image}" "${db_url}"
  local engine_ok=1
  if [ -n "${ENGINE_SOCKET}" ]; then verify_engine_from_agent || engine_ok=0; fi
  if [ -z "${REMOTE_UI_URL}" ]; then
    start_ui "${ui_image}" "${db_url}"
    step "Signing you up"
    bootstrap_ui
  fi

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
  echo "  Checks run:   $([ -n "${ENGINE_SOCKET}" ] && [ "${engine_ok}" = 1 ] && echo "in toolchain containers" || echo "inside the agent container")"
  echo "  Saved in:     ${STATE_FILE}"
  echo "  ${DIM}Status: ${SELF} status   Logs: ${RUNTIME} logs -f ${AGENT_CONTAINER}   Stop: ${SELF} down${RESET}"
}

"action_${ACTION}"
