# Fluxline

Fluxline is an AI-assisted software delivery control plane. You describe a change — or pull it
straight from Jira — and Fluxline reviews the requirement, plans the work, has a coding agent
implement it in your repositories, runs your checks, and stops for your approval before anything
is published.

It ships as two Docker images:

| Image | What it is | Port |
|---|---|---|
| `suneshantanu/fluxline-ui` | Web control center (tasks, approvals, Jira, settings) | `3000` |
| `suneshantanu/fluxline-agent` | Agent that runs the pipeline against your repositories | `3400` |

Both are published per architecture: use the `:arm64` tag on Apple Silicon / ARM servers and
`:amd64` on Intel/AMD machines. The examples below use `:arm64`.

> **Full reference:** [`HELP.html`](HELP.html) has every setup below plus a complete index of
> every environment variable. Download it and open it in a browser.

---

## Quick start — everything on one machine

Three containers on one Docker network: Postgres, the agent, and the UI.

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

Then open **http://localhost:3000**. The first visit creates the admin account — there is no
separate password variable or bootstrap step.

- `-v /var/run/docker.sock:/var/run/docker.sock` lets the agent run your builds and tests in
  toolchain containers (Maven, Gradle, Node, Go, Python, Rust). Without it, checks run inside the
  agent's own shell.
- `-v fluxline-agent-data:/data` keeps the agent's configuration and secrets across restarts —
  always mount a volume there.

---

## Other setups

### Local UI and agent, managed database

Use an existing Postgres (RDS, Supabase, Neon, …) instead of a local container:

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

### Hosted UI, agent on your own machine

The UI already runs somewhere for your team. Run only the agent locally and link it with a
personal access token (hosted UI → **Settings → Agent tokens → New token**):

```bash
docker run -d --name fluxline-agent -p 3400:3400 \
  -v fluxline-agent-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e AI_SDLC_REMOTE_UI_URL=https://fluxline.yourcompany.com \
  -e AI_SDLC_AGENT_TOKEN=fxln_pat_... \
  suneshantanu/fluxline-agent:arm64
```

### Agent only (headless)

No UI — call the agent's HTTP API directly from scripts or CI:

```bash
docker run -d --name fluxline-agent -p 3400:3400 \
  -v fluxline-agent-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e AI_SDLC_API_TOKEN=choose-a-fixed-token \
  suneshantanu/fluxline-agent:arm64

curl -H "Authorization: Bearer choose-a-fixed-token" http://localhost:3400/runtime
```

If you don't set `AI_SDLC_API_TOKEN`, one is generated on first boot:
`docker logs fluxline-agent | grep Bearer`.

---

## Configuration

### Agent (`fluxline-agent`)

| Variable | Required | Description |
|---|---|---|
| `AI_SDLC_DATABASE_URL` | recommended | Postgres URL for run state. Omit to keep state in memory (lost on restart). |
| `AI_SDLC_API_TOKEN` | no | Fixes the token the UI uses to call the agent. Generated on first boot if unset. |
| `AI_SDLC_ALLOWED_ORIGINS` | no | Comma-separated browser origins allowed to call the agent. Defaults to localhost. |
| `AI_SDLC_CHECKPOINTER` | no | `memory`, `postgres` or `remote` — normally picked automatically. |
| `AI_SDLC_REMOTE_UI_URL` / `AI_SDLC_AGENT_TOKEN` | hosted UI only | Link the agent to a hosted UI. |
| `ANTHROPIC_API_KEY` | for Claude | Or mount `~/.claude` to reuse an existing CLI login. |
| `OPENAI_API_KEY` | for Codex | Or mount `~/.codex`. |
| `GH_COPILOT_TOKEN` | for Copilot | Hosted Copilot coding agent. |
| `AI_SDLC_GITHUB_ENABLED` / `AI_SDLC_GITHUB_TOKEN` | no | Open pull requests on GitHub. |
| `AI_SDLC_GITLAB_ENABLED` / `AI_SDLC_GITLAB_TOKEN` | no | Open merge requests on GitLab. |
| `AI_SDLC_JIRA_ENABLED` / `AI_SDLC_JIRA_API_URL` / `AI_SDLC_JIRA_EMAIL` / `AI_SDLC_JIRA_TOKEN` | no | Jira integration (can also be set from the UI's Credentials screen). |

### UI (`fluxline-ui`)

| Variable | Required | Description |
|---|---|---|
| `DATABASE_URL` | yes | Same Postgres the agent uses. Or set `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` instead. |
| `DB_POOL_MAX` | no | Max database connections for this UI instance (default 10). |
| `DB_POOL_IDLE_TIMEOUT_MS` | no | How long an idle connection stays open (default 30000). |

---

## Highlights

- **Requirement review with a clarity score** — every request is scored 0–100 before work
  starts, and unclear ones stop for a human.
- **Jira auto-pull** — save a Jira filter (JQL, labels, issue types), and Fluxline polls it and
  turns matching tickets into tasks one at a time (configurable). Tickets below 65% clarity are
  blocked, clear ones wait for approval, and — if you allow it — 90%+ tickets run on autopilot.
- **Approvals where they matter** — requirement, plan, change set and merge gates, each optional.
- **Checks in real toolchains** — builds and tests run in language-specific containers.
- **Task history** — select tasks to cancel or restart in bulk.

See [`HELP.html`](HELP.html) for the complete deployment reference.
