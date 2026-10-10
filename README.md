# Fluxline

**AI-assisted software delivery, on your own machine.**

Describe a change — or pull it straight from Jira — and Fluxline reviews it, plans the work, has a
coding agent (VS Code with Copilot Chat, Claude or Codex) make it in your repositories, runs your
builds and tests, and stops for your approval before it opens a pull request.

![Fluxline in a minute: sign in, create a workspace, turn on a coding agent, let it write the workspace's skills from the code, start a task, review it, and get the tested change on its own branch](docs/fluxline-walkthrough.gif)

## Get started

1. **Install** [Docker Desktop](https://www.docker.com/products/docker-desktop/) or
   [Podman](https://podman-desktop.io/downloads).
2. **Download the app** from the [latest release](https://github.com/shantanusune/fluxline/releases/latest)
   (macOS, Apple Silicon). Unzip it and open **Fluxline** — the first time, right-click → **Open**.
   Windows and Linux versions are coming soon.
3. **Let it start.** Fluxline finds Docker or Podman, asks for your code folder (optional), starts,
   and ends on a dashboard with the address and your login.
4. **Add a workspace** — a folder with your repositories, or an empty one
   (**Configuration → Workspaces**).
5. **Turn on a coding agent** — Claude or Codex (paste an API key), or VS Code with Copilot Chat
   (**Configuration → Agents**).
6. **Start a change.** Click **+ New change**, describe the outcome, and let Fluxline plan, build,
   test, and wait for your approval before it publishes the change on its own branch.

Everything else — Jira, Git credentials, workspace skills, build checks — is a click away in the
app. Your settings and keys are kept on your computer (`~/.fluxline`), so removing Fluxline never
loses them.

## What you need

- **macOS on Apple Silicon** (Intel Mac, Windows and Linux coming soon).
- **Docker Desktop** or **Podman**.
- A coding-agent sign-in: **Claude**, **Codex**, or **VS Code** with **Copilot Chat**.

## License

[PolyForm Noncommercial 1.0.0](LICENSE): free for personal use and other noncommercial purposes
(study, research, hobby projects, charities, schools, public bodies). Commercial use needs a
separate license from the author. The `fluxline-standalone` images are licensed the same way.

---

© 2026 Shantanu Sune · For developers, by developers
