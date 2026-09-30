# Fluxline

**AI-assisted software delivery you can run with two Docker containers.**

Describe a change — or pull it straight from Jira — and Fluxline reviews the requirement, plans
the work, has a coding agent (Claude, Codex, Copilot or VS Code) implement it in your
repositories, runs your builds and tests, and stops for your approval before anything is
published as a pull request.

| Image | What it runs | Port |
|---|---|---|
| [`suneshantanu/fluxline-ui`](https://hub.docker.com/r/suneshantanu/fluxline-ui) | Web control center: tasks, approvals, Jira, settings, users | `3000` |
| [`suneshantanu/fluxline-agent`](https://hub.docker.com/r/suneshantanu/fluxline-agent) | The pipeline: requirement review, planning, coding agent, checks, PRs | `3400` |

Each image is published per CPU architecture — use **`:arm64`** on Apple Silicon and ARM
servers, **`:amd64`** on Intel/AMD machines. The examples below use `:arm64`.

## Contents

- [What you get](#what-you-get)
- [Choose a setup](#choose-a-setup)
- [1. Everything on one machine](#1-everything-on-one-machine)
- [2. Local containers, managed database](#2-local-containers-managed-database)
- [3. Hosted UI, agent on your machine](#3-hosted-ui-agent-on-your-machine)
- [4. Agent only (headless)](#4-agent-only-headless)
- [Volumes and mounts](#volumes-and-mounts)
- [Environment variables](#environment-variables)
- [Day-to-day operations](#day-to-day-operations)
- [Troubleshooting](#troubleshooting)

---

## What you get

- **Requirement review with a clarity score.** Every request is scored 0–100 against your
  repositories' own docs before work starts; unclear ones stop for a human with a list of what's
  missing.
- **Jira auto-pull.** Save a Jira filter (JQL, labels, issue types — all combined), and Fluxline
  polls it every 1–10 seconds and turns matching tickets into tasks, a configurable number at a
  time. Below 65% clarity a ticket is created but blocked; clear ones wait for approval; and, if
  you allow it, 90%+ tickets run fully on autopilot.
- **Approval gates where they matter.** Requirement, analysis, plan, change set and merge — each
  optional, or skip them all per task with autopilot.
- **Checks in real toolchains.** Builds and tests run in language-specific containers (Maven,
  Gradle, Node, Go, Python, Rust) picked from each repository's manifest.
- **Task history.** Every task, filterable and searchable; select several to cancel or restart
  in one go.
- **Team features.** User accounts, roles and per-menu access control, agent tokens for linking
  locally running agents to a shared UI.

---

## Choose a setup

| Setup | Containers | Database | Use it when |
|---|---|---|---|
| [1. Everything on one machine](#1-everything-on-one-machine) | UI + agent + Postgres | local container | Trying Fluxline out, or a single-user install |
| [2. Managed database](#2-local-containers-managed-database) | UI + agent | RDS / Supabase / Neon … | You already run Postgres somewhere |
| [3. Hosted UI, local agent](#3-hosted-ui-agent-on-your-machine) | agent only | the hosted UI's | Your team shares one UI; each developer runs an agent next to their code |
| [4. Agent only](#4-agent-only-headless) | agent only | optional | Scripting, CI, or your own frontend |

---

## 1. Everything on one machine

Three containers on one Docker network. Nothing is reachable from outside your machine.

```bash
docker network create fluxline-net

docker run -d --name fluxline-db --network fluxline-net \
  -e POSTGRES_PASSWORD=changeme \
  -v fluxline-db-data:/var/lib/postgresql/data \
  postgres:17-alpine

docker run -d --name fluxline-agent --network fluxline-net -p 3400:3400 \
  -v fluxline-agent-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e AI_SDLC_DATABASE_URL=postgres://postgres:changeme@fluxline-db:5432/postgres \
  suneshantanu/fluxline-agent:arm64

docker run -d --name fluxline-ui --network fluxline-net -p 3000:3000 \
  -e DATABASE_URL=postgres://postgres:changeme@fluxline-db:5432/postgres \
  suneshantanu/fluxline-ui:arm64
```

Open **http://localhost:3000**. The first visit creates the admin account — there is no
separate bootstrap step or password variable.

<details>
<summary><b>Full version</b> — fixed API token, a coding provider, GitHub PRs, pool tuning</summary>

```bash
docker run -d --name fluxline-agent --network fluxline-net -p 3400:3400 \
  -v fluxline-agent-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.claude:/root/.claude:ro \
  -e AI_SDLC_DATABASE_URL=postgres://postgres:changeme@fluxline-db:5432/postgres \
  -e AI_SDLC_CHECKPOINTER=postgres \
  -e AI_SDLC_ALLOWED_ORIGINS=http://localhost:3000 \
  -e AI_SDLC_API_TOKEN=choose-a-fixed-token \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  -e OPENAI_API_KEY=sk-... \
  -e AI_SDLC_GITHUB_ENABLED=true \
  -e AI_SDLC_GITHUB_TOKEN=ghp_... \
  suneshantanu/fluxline-agent:arm64

docker run -d --name fluxline-ui --network fluxline-net -p 3000:3000 \
  -e DATABASE_URL=postgres://postgres:changeme@fluxline-db:5432/postgres \
  -e DB_POOL_MAX=20 \
  -e DB_POOL_IDLE_TIMEOUT_MS=30000 \
  suneshantanu/fluxline-ui:arm64
```

You only need the key for the provider(s) you actually use — see
[Coding providers](#coding-providers).
</details>

---

## 2. Local containers, managed database

Both containers stay on your machine; Postgres is a managed instance. No `fluxline-db`
container and no Docker network needed.

```bash
docker run -d --name fluxline-agent -p 3400:3400 \
  -v fluxline-agent-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e AI_SDLC_DATABASE_URL="postgres://USER:PASS@your-db-host:5432/fluxline?sslmode=require" \
  suneshantanu/fluxline-agent:arm64

docker run -d --name fluxline-ui -p 3000:3000 \
  -e DATABASE_URL="postgres://USER:PASS@your-db-host:5432/fluxline?sslmode=require" \
  suneshantanu/fluxline-ui:arm64
```

<details>
<summary><b>Full version</b> — database as separate parts instead of one URL</summary>

```bash
docker run -d --name fluxline-agent -p 3400:3400 \
  -v fluxline-agent-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e AI_SDLC_DATABASE_URL="postgres://USER:PASS@your-db-host:5432/fluxline?sslmode=require" \
  -e AI_SDLC_CHECKPOINTER=postgres \
  suneshantanu/fluxline-agent:arm64

docker run -d --name fluxline-ui -p 3000:3000 \
  -e DB_HOST=your-db-host \
  -e DB_PORT=5432 \
  -e DB_USER=fluxline \
  -e DB_PASSWORD=PASS \
  -e DB_NAME=fluxline \
  -e DB_POOL_MAX=20 \
  suneshantanu/fluxline-ui:arm64
```

`DATABASE_URL` always wins over the separate `DB_*` parts if both are set.
</details>

---

## 3. Hosted UI, agent on your machine

The UI already runs somewhere for your team, with its own database. Each developer runs only
the agent, next to their repositories, and links it to the UI with a personal access token — no
local Postgres at all.

1. In the hosted UI, go to **Settings → Agent tokens → New token**.
2. Run the agent with that token:

```bash
docker run -d --name fluxline-agent -p 3400:3400 \
  -v fluxline-agent-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e AI_SDLC_REMOTE_UI_URL=https://fluxline.yourcompany.com \
  -e AI_SDLC_AGENT_TOKEN=fxln_pat_... \
  suneshantanu/fluxline-agent:arm64
```

The agent reports run history and reads workspace settings through the hosted UI; the history
you see there is tied to that exact token.

<details>
<summary><b>Full version</b> — explicit checkpointer and a coding provider</summary>

```bash
docker run -d --name fluxline-agent -p 3400:3400 \
  -v fluxline-agent-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.ai-sdlc:/vscode-bridge-registry:ro \
  -e AI_SDLC_REMOTE_UI_URL=https://fluxline.yourcompany.com \
  -e AI_SDLC_AGENT_TOKEN=fxln_pat_... \
  -e AI_SDLC_CHECKPOINTER=remote \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  suneshantanu/fluxline-agent:arm64
```
</details>

---

## 4. Agent only (headless)

No UI — call the agent's HTTP API directly. Run state is kept in memory unless you give it a
database.

```bash
docker run -d --name fluxline-agent -p 3400:3400 \
  -v fluxline-agent-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e AI_SDLC_API_TOKEN=choose-a-fixed-token \
  suneshantanu/fluxline-agent:arm64

curl -H "Authorization: Bearer choose-a-fixed-token" http://localhost:3400/runtime
```

If you don't set `AI_SDLC_API_TOKEN`, the agent generates one on first boot and prints it:

```bash
docker logs fluxline-agent | grep Bearer
```

<details>
<summary><b>Full version</b> — persistent Postgres state</summary>

```bash
docker run -d --name fluxline-agent -p 3400:3400 \
  -v fluxline-agent-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e AI_SDLC_API_TOKEN=choose-a-fixed-token \
  -e AI_SDLC_DATABASE_URL=postgres://USER:PASS@your-db-host:5432/fluxline \
  -e AI_SDLC_CHECKPOINTER=postgres \
  suneshantanu/fluxline-agent:arm64
```
</details>

---

## Volumes and mounts

All of these are for the **agent** container; the UI needs none.

| Mount | Needed? | Why |
|---|---|---|
| `-v fluxline-agent-data:/data` | **Always** | Configuration, saved credentials and the generated API token. Without it they're lost when the container is recreated. |
| `-v /var/run/docker.sock:/var/run/docker.sock` | Recommended | Runs builds and tests in toolchain containers (Maven/Gradle/Node/Go/Python/Rust image chosen from each repository's manifest; caches kept in `fluxline-toolchain-*` volumes; `~/.m2/settings.xml`, `~/.npmrc`, `pip.conf` and `gradle.properties` copied in). Without it, checks run in the agent's own shell. |
| `-v ~/.claude:/root/.claude:ro` | Optional | Reuse an existing Claude CLI login instead of `ANTHROPIC_API_KEY`. |
| `-v ~/.codex:/root/.codex:ro` | Optional | Reuse an existing Codex CLI login instead of `OPENAI_API_KEY`. |
| `-v ~/.ai-sdlc:/vscode-bridge-registry:ro` | VS Code provider only | Lets the agent find the VS Code bridge running on your machine. |
| Your repositories | For real work | Mount the folder that holds your repositories, and point the workspace at it in **Settings → Workspace**. The run directory must be on a mounted volume too. |

---

## Environment variables

### Agent — core and networking

| Variable | Default | Description |
|---|---|---|
| `AI_SDLC_DATABASE_URL` | — | Postgres URL for run state. Omit to keep state in memory (lost on restart). |
| `AI_SDLC_CHECKPOINTER` | auto | `memory`, `postgres` or `remote` — normally picked from the variables you set. |
| `AI_SDLC_API_TOKEN` | generated | Token the UI (or your scripts) must send as `Authorization: Bearer …`. Generated and saved to `/data` on first boot if unset. |
| `AI_SDLC_ALLOWED_ORIGINS` | localhost | Comma-separated browser origins allowed to call the agent — add your UI's URL if it isn't `http://localhost:3000`. |
| `AI_SDLC_HOST` / `AI_SDLC_PORT` | `0.0.0.0` / `3400` | Already set in the image; override only for unusual networking. |

### Agent — data and paths

| Variable | Default | Description |
|---|---|---|
| `AI_SDLC_DATA_DIR` | `/data` | Configuration and secrets root. Always mount a volume here. |
| `AI_SDLC_AGENTS_CONFIG` | `/data/agents.yaml` | Coding-provider configuration. |
| `AI_SDLC_WORKSPACE_CONFIG` | `/data/workspace.yaml` | Active workspace definition. |
| `AI_SDLC_PIPELINE_CONFIG` | `/data/pipeline.yaml` | Pipeline and checks configuration (`check_runtime: auto \| container \| host`). |
| `AI_SDLC_CONTAINER_ID` | auto | This container's name/id, used to give toolchain containers the same mounts. Set only if detection fails. |

### Agent — hosted UI link

| Variable | Description |
|---|---|
| `AI_SDLC_REMOTE_UI_URL` | Base URL of the hosted UI (setup 3). |
| `AI_SDLC_AGENT_TOKEN` | Personal access token from that UI's **Agent tokens** screen. |

### Agent — source control and Jira

| Variable | Default | Description |
|---|---|---|
| `AI_SDLC_GITHUB_ENABLED` / `AI_SDLC_GITHUB_TOKEN` | `false` | Push branches and open pull requests on GitHub. |
| `AI_SDLC_GITLAB_ENABLED` / `AI_SDLC_GITLAB_TOKEN` | `false` | Same, for GitLab merge requests. |
| `AI_SDLC_JIRA_ENABLED` / `AI_SDLC_JIRA_API_URL` / `AI_SDLC_JIRA_EMAIL` / `AI_SDLC_JIRA_TOKEN` | `false` | Jira integration. All of these can also be entered in the UI under **Credentials** instead. |

### Coding providers

You only need credentials for the provider(s) you use.

| Variable | Provider | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | Claude | Or mount `~/.claude`. |
| `OPENAI_API_KEY` | Codex | Or mount `~/.codex`. |
| `GH_COPILOT_TOKEN` | Copilot | Hosted Copilot coding agent. |
| — | VS Code | Needs no key: it drives Copilot Chat inside a real VS Code window. Install the bridge extension from the UI's **Settings → Agents**. |

### UI

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | — | Same Postgres the agent uses. Required unless the `DB_*` parts are set. |
| `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD` / `DB_NAME` | port `5432` | Used only when `DATABASE_URL` is unset. |
| `DB_POOL_MAX` | `10` | Max database connections this UI instance opens. |
| `DB_POOL_IDLE_TIMEOUT_MS` | `30000` | How long an idle connection stays open. |

There is no admin-password variable — the first browser visit creates the one admin account.

---

## Day-to-day operations

**Connect the UI to the agent.** In the UI's connection panel, use `http://localhost:3400` and
the agent's API token (`AI_SDLC_API_TOKEN`, or the one from `docker logs fluxline-agent | grep Bearer`).

**Health checks.**

```bash
curl http://localhost:3400/health           # agent liveness, no token needed
docker inspect --format '{{.State.Health.Status}}' fluxline-ui
```

**Upgrade.** Pull the new images and recreate the containers with the same volumes and variables —
your data lives in the volumes, not the containers:

```bash
docker pull suneshantanu/fluxline-agent:arm64 suneshantanu/fluxline-ui:arm64
docker rm -f fluxline-agent fluxline-ui
# re-run the same `docker run` commands as before
```

**Logs.** `docker logs -f fluxline-agent` shows every pipeline step; each task's own live log is
also in the UI.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| UI says it can't reach the control plane | Check the agent is up (`curl localhost:3400/health`), and that the UI's URL is listed in `AI_SDLC_ALLOWED_ORIGINS` if it isn't `http://localhost:3000`. |
| `401 Missing or invalid API token` | The token in the UI's connection panel doesn't match the agent's — see [Connect the UI to the agent](#day-to-day-operations). |
| Tasks disappear after a restart | The agent has no database: set `AI_SDLC_DATABASE_URL`. |
| Builds/tests fail with "command not found" | Mount the Docker socket so checks run in toolchain containers, or set `check_runtime: host` and install the tools yourself. |
| Settings reset after recreating the agent | Mount a volume at `/data`. |
