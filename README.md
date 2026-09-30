# Fluxline control center

Fluxline connects the web control center to the Python AI SDLC orchestration service. From the UI
you can submit a change, watch live pipeline state, inspect checks and changed files, view browser
evidence, read logs, approve the exact published commit heads, reject a change, recheck a blocked
merge, or provide an advanced resume payload.

## Start the control center

From the repo root, run:

```bash
./start-control-center.sh
```

This is the one script — it replaces what used to be several separate ones. `--agent-only` or
`--ui-only` runs just that half (point `--ui-only` at an agent running elsewhere from the UI's own
connection panel); with neither flag it runs both, UI first, only starting the agent once the UI
has confirmed ready (see "Shared database config" below for why that order matters).

On first run the launcher: asks for database connection details if none are configured yet
(writing them to `config.json` — see "Shared database config" below), starts that Postgres via
`docker compose` automatically if it's configured for localhost but nothing is listening there yet,
creates the backend's Python virtual environment (`ai-sdlc-stack-skeleton/.venv`) and installs its
dependencies (also rebuilding it automatically if it's stale, e.g. after this directory moves), and
installs the UI's `node_modules` if missing. It then starts the backend and UI together and opens
`http://127.0.0.1:5173`. Subsequent runs reuse the existing venv, `node_modules`, and database
config, and start up immediately.

The launcher picks its config in this order:

1. `AI_SDLC_WORKSPACE_CONFIG` / `AI_SDLC_PIPELINE_CONFIG`, if both are set in your shell.
2. The disposable, fully-simulated demo (no real commits, fake PR URLs), if `AI_SDLC_DEMO_MODE=1`.
3. `ai-sdlc-stack-skeleton/config/workspace.local.yaml` + `pipeline.local.yaml`, if present — a
   **gitignored, machine-local** config pointing at a real on-disk workspace with
   `scm_provider: local`, so approved changes are genuinely committed and merged into that
   checkout, no mock/dry-run involved.
4. Otherwise, the disposable demo (same as #2) — this is the safe fallback on a machine that has
   no local config yet, so a fresh clone never crashes trying to resolve someone else's path.

To set up real mode on a machine, copy the committed templates and edit the workspace path:

```bash
cp ai-sdlc-stack-skeleton/config/workspace.example.yaml ai-sdlc-stack-skeleton/config/workspace.local.yaml
cp ai-sdlc-stack-skeleton/config/pipeline.example.yaml ai-sdlc-stack-skeleton/config/pipeline.local.yaml
# edit workspace.local.yaml: set workspace_root to your repository's absolute path on this machine
./start-control-center.sh
```

`config/*.example.yaml` are portable templates committed to git — they intentionally contain no
machine-specific paths. `config/*.local.yaml` are gitignored and hold your real, per-machine
settings; they never get committed or shared.

To force the disposable demo even when a local config exists, set `AI_SDLC_DEMO_MODE=1`:

```bash
AI_SDLC_DEMO_MODE=1 ./start-control-center.sh
```

Real Codex, Claude, PostgreSQL, and GitHub/GitLab modes also require their optional backend
packages and credentials — see `ai-sdlc-stack-skeleton/README.md`. Keep the backend on localhost
until authentication and authorization are enabled.

## Remote control plane

The UI connection panel lets you save several connections (backend URL + API token) and switch
between them — one per machine/workspace running its own local agent. Saved connections live in
the UI's own database, following your account across browsers/machines; which one is active in a
given browser tab is a lightweight local preference. Each local agent's `AI_SDLC_ALLOWED_ORIGINS`
must include every origin that will connect to it — it accepts a comma-separated list (see
`api.py`), so list every hosted-UI origin (and any local dev origins you still use) there.

The Python control API requires `Authorization: Bearer <token>` on every request by default. The
first time an agent boots with no token configured (`AI_SDLC_API_TOKEN`, or `api_token` in
`~/.ai_sdlc/configuration.json`), it generates one, saves it to that file, and prints it once —
paste that value into the UI's connection panel (or set `AI_SDLC_API_TOKEN` for another kind of
caller) so requests can authenticate. Still exercise normal caution before exposing an agent
beyond loopback/a private tunnel: the token is the only control this process has of its own.

Two supported shapes for "hosted UI, local agent":

- **A UI on a real domain talking to `http://127.0.0.1:<port>` on the same machine the browser is
  running on** (the common case: you open the hosted UI in your own browser, and your own agent is
  running on your own laptop). This works directly — no tunnel needed — because the target is
  loopback. Chrome additionally requires the agent to opt into Private Network Access on its CORS
  preflight, which `api.py`'s `_allow_private_network_preflight` middleware already sends; nothing
  extra to configure. Note this only ever works from the browser on the *same machine* as the
  agent — a URL like `http://127.0.0.1:3400` is meaningless from anyone else's browser.
- **A tunneled/HTTPS-exposed agent** (e.g. via a reverse tunnel) reachable from other machines —
  add its public HTTPS URL as a saved connection and its origin to `AI_SDLC_ALLOWED_ORIGINS` as
  above.

There is no way for a hosted web page to launch the local agent process itself — browsers cannot
start arbitrary local programs, by design. Start it yourself (`./start-control-center.sh` or your
own equivalent) before connecting to it from the UI; the connection panel's status indicator shows
whether it can currently reach whatever URL is configured.

## Shared database config

For "local agent + hosted/local UI, both backed by one Postgres" — no HTTP hop between them at
all — create `config.json` at the repo root (copy `config.json.example`, gitignored, never
committed) with a `"database"` block (`url`, or discrete `host`/`port`/`user`/`password`/
`database`). Both halves read it as a fallback, only when their usual env var isn't already set
(`DATABASE_URL`/`DB_HOST` for the UI, `AI_SDLC_DATABASE_URL` for the agent) — an env var always
wins, so this has no effect on a real deployment using secrets/env vars, and a Cloudflare Workers
deployment or the UI's Docker container simply has no `config.json` on its filesystem to find.

When the agent picks up a database URL from `config.json` specifically (not its own
`AI_SDLC_DATABASE_URL`), it defaults `checkpointer` to `shared_db`: it writes directly into the
UI's own `agent_workspaces`/`agent_runs`/`agent_run_audit_events`/`agent_checkpoint_chunks` tables
(see `services/shared_db.py` and each `SharedDb*` class) instead of calling its `/api/agent/**`
HTTP API — no `AI_SDLC_REMOTE_UI_URL`/`AI_SDLC_AGENT_TOKEN`, no bearer-token auth hop, nothing
running on the UI side beyond the database itself. This is the simplest way to get "agent and UI
share state" working, and the one to reach for first if `remote` mode's HTTP+token path is giving
you trouble.

Every row in those tables needs a UI account (`user_id`) to belong to — `shared_db` mode resolves
one once, at startup: `AI_SDLC_SHARED_DB_USER_EMAIL` (or `shared_db_user_email` in
`~/.ai_sdlc/configuration.json`) if set, otherwise the first admin account it finds. The common
case (one UI account, one agent) needs no configuration here at all.

Compare with the two other ways an agent can persist durable state:

- `postgres` (`AI_SDLC_DATABASE_URL` set directly, not via `config.json`): the agent's own,
  separate Postgres and its own `ai_sdlc_*` tables — nothing to do with the UI, no UI required at
  all. Independent of `shared_db` mode even if it happens to point at the same physical database:
  different table names, so the two don't collide, but they also don't share data.
- `remote` (`AI_SDLC_REMOTE_UI_URL` + `AI_SDLC_AGENT_TOKEN`): the original HTTP+bearer-token path,
  still useful when the agent genuinely can't reach the UI's database directly (a real network
  boundary between them) — see "Remote control plane" above for that shape.

## Deploying the UI's image

`ai-sdlc-control-center-source/scripts/build-image.sh <tag>` builds the production image (see its
own `Dockerfile`) — the UI reads its database connection from plain environment variables in
production (`DATABASE_URL`, or the discrete `DB_HOST`/`DB_PORT`/`DB_USER`/`DB_PASSWORD`/`DB_NAME`
— same shape as everywhere else in this doc, deliberately not tied to any one hosting platform),
so it runs the same way on ECS, plain `docker run -e`, or anywhere else. See
`ai-sdlc-control-center-source/deploy/ecs/app.env.example` for the full list of variables it reads
and `deploy/ecs/task-definition.example.json` for an example Fargate task definition (DB_PASSWORD
pulled from Secrets Manager via `secrets`, everything else in plain `environment`).

`ai-sdlc-control-center-source/db/ddl/schema.sql` is a standalone copy of the schema the app
creates for itself on first request (`ensureSchema()` in `db/index.ts`) — for environments where
the app's own database user shouldn't have DDL permissions, or where you'd rather have your own
migration tooling apply it up front. Running it is optional either way; the app's own self-check
finds nothing to do against a database that already has it.

## Git/SCM credentials

GitHub, GitLab, and Artifactory tokens saved from Settings (or `AI_SDLC_GITHUB_TOKEN` etc. as
environment variables, which always take precedence) are written to
`~/.ai_sdlc/configuration.json` — a fixed location on whichever machine runs the Python backend,
independent of which project checkout launched it. This file is never read by, or synced to, the
UI's own backend/database; it stays on the machine running the agent. If you have an older setup
with these tokens in this project's `.env` file, either move them into
`~/.ai_sdlc/configuration.json` yourself (same field names, without the `AI_SDLC_` prefix and
without the trailing `_TOKEN`/`_URL` suffix casing, e.g. `AI_SDLC_GITHUB_TOKEN` → `github_token`)
or just re-save them from Settings — the old `.env` values still work as environment-variable
overrides in the meantime.
