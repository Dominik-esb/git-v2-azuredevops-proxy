# Git Protocol v2 Proxy for Azure DevOps

A Docker container that acts as a local Git Smart HTTP server with **protocol v2** support, proxying an Azure DevOps repository that only speaks protocol v1.

## Why

Azure DevOps does not support Git HTTP protocol v2. Some tools (CI systems, IDEs, custom tooling) require or benefit from v2's more efficient ref negotiation. This container sits in between:

```
your client (v2)  →  container (v1↔v2 bridge)  →  Azure DevOps (v1)
```

## How it works

| Direction | Trigger | Mechanism |
|---|---|---|
| Azure DevOps → local | Every `SYNC_INTERVAL` seconds | Background `git fetch --mirror` |
| Local → Azure DevOps | On every client push | `post-receive` hook forwards the push upstream |

Clones and fetches are served locally at full speed with protocol v2. Pushes are transparently forwarded to Azure DevOps in real time.

## Requirements

- Docker + Docker Compose
- Azure DevOps Personal Access Token with **Code → Read & Write** scope

## Setup

```bash
cp .env.example .env
# edit .env with your values
docker compose --env-file .env up -d --build
```

## Configuration

| Variable | Required | Description |
|---|---|---|
| `AZURE_DEVOPS_URL` | Yes | Full HTTPS URL to the repo, e.g. `https://dev.azure.com/org/project/_git/repo` |
| `AZURE_PAT` | Yes | Personal Access Token |
| `REPO_NAME` | Yes | Local repo name clients use to clone, e.g. `myrepo.git` |
| `SYNC_INTERVAL` | No | Seconds between background fetches (default: `60`) |

## Usage

```bash
# Clone
git clone http://localhost:7080/<REPO_NAME>

# Force protocol v2 explicitly
git -c protocol.version=2 clone http://localhost:7080/<REPO_NAME>

# Push — forwarded to Azure DevOps automatically
git push
```

## Verify protocol v2

```bash
GIT_TRACE_PACKET=1 git -C <repo> fetch 2>&1 | head -5
# Look for: packet: ... version 2
```

## Logs

```bash
docker logs -f git-v2-proxy
```

## License

MIT — see [LICENSE](LICENSE)
