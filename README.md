# git-v2-azuredevops-proxy

[![CI](https://github.com/Dominik-esb/git-v2-azuredevops-proxy/actions/workflows/ci.yml/badge.svg)](https://github.com/Dominik-esb/git-v2-azuredevops-proxy/actions/workflows/ci.yml)
[![Security](https://github.com/Dominik-esb/git-v2-azuredevops-proxy/actions/workflows/security.yml/badge.svg)](https://github.com/Dominik-esb/git-v2-azuredevops-proxy/actions/workflows/security.yml)
[![Release](https://img.shields.io/github/v/release/Dominik-esb/git-v2-azuredevops-proxy?logo=github)](https://github.com/Dominik-esb/git-v2-azuredevops-proxy/releases/latest)
[![Docker Pulls](https://img.shields.io/docker/pulls/dominikesb/git-v2-azuredevops-proxy?logo=docker)](https://hub.docker.com/r/dominikesb/git-v2-azuredevops-proxy)
[![License](https://img.shields.io/github/license/Dominik-esb/git-v2-azuredevops-proxy)](LICENSE)

A Git Smart HTTP server with **protocol v2** in front of Azure DevOps, which only speaks protocol v1.

Azure DevOps does not support Git protocol v2. Tools that require it — for example
[Grafana Git Sync](docs/grafana.md) — cannot talk to Azure DevOps directly. This proxy keeps a
mirror of your repositories, serves clones and fetches with protocol v2, and forwards pushes to
Azure DevOps.

```
git client (v2)  ──▶  git-v2-azuredevops-proxy  ──▶  Azure DevOps (v1)
```

## Features

- **Protocol v2** clones and fetches, served from a local mirror
- **Push forwarding** — pushes and branch deletions go straight to Azure DevOps
- **Several repositories** per instance, each with its own generated access token
- **Azure DevOps authentication** with a PAT, or with Microsoft Entra (workload identity or client secret) — no PAT to rotate
- **HTTP and HTTPS**, with an auto-generated self-signed certificate or your own
- **Kubernetes manifests** — a kustomize base plus one overlay per authentication method
- Multi-arch image (`linux/amd64`, `linux/arm64`) with SBOM and provenance

## How it works

| Direction | Trigger | Mechanism |
|---|---|---|
| Azure DevOps → proxy | Every `SYNC_INTERVAL` seconds | Background `git fetch` into a mirror |
| Proxy → Azure DevOps | Every client push | A `post-receive` hook forwards the push |

## Quick start

```bash
docker run -d --name git-v2-proxy \
  -p 7080:80 -p 7443:8443 \
  -e AZURE_DEVOPS_URL=https://dev.azure.com/<org>/<project>/_git/<repo> \
  -e AZURE_PAT=<pat> \
  -v git-repos:/repos \
  dominikesb/git-v2-azuredevops-proxy:1
```

The proxy prints a generated access token per repository to its log:

```bash
docker logs git-v2-proxy | grep -A5 '\[credentials\]'
```

Then clone with protocol v2, using the repository name as user name and the token as password:

```bash
git -c protocol.version=2 clone http://<repo>:<token>@localhost:7080/<repo>.git
```

Pushes to that clone are forwarded to Azure DevOps.

### Several repositories

Mount a `repos.conf` with one repository per line. The local path is derived from the
repository name, so `…/_git/repo1` is served at `/repo1.git`:

```
# <AZURE_DEVOPS_URL>                              <PAT>
https://dev.azure.com/myorg/myproject/_git/repo1  pat1here
https://dev.azure.com/myorg/myproject/_git/repo2  pat2here
```

With [`docker-compose.yml`](docker-compose.yml):

```bash
cp repos.conf.example repos.conf   # contains PATs: keep it secret, never commit it
docker compose up -d
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `AZURE_DEVOPS_URL` | — | Single-repo mode: the repository URL, used when no `repos.conf` is mounted |
| `AZURE_PAT` | — | Single-repo mode: the PAT for `AZURE_DEVOPS_URL` |
| `REPOS_CONF` | `/etc/git-proxy/repos.conf` | Path of the multi-repo config |
| `SYNC_INTERVAL` | `60` | Seconds between background fetches from Azure DevOps |
| `GIT_PROXY_AUTH` | `basic` | `basic`: a generated token per repository, printed to the log. `none`: no authentication on the git endpoints — anyone who can reach the proxy can then **push** to Azure DevOps as its identity, so only use it behind a NetworkPolicy (see [`k8s/components/network-policy`](k8s/components/network-policy)) |
| `UPSTREAM_AUTH` | `auto` | `auto`: Entra when its variables are complete, otherwise PAT. Set `pat` or `entra` to choose explicitly — recommended on AKS, where the workload identity webhook injects the `AZURE_*` variables into any labelled pod |
| `AZURE_CLIENT_ID` | — | Entra: client ID of the app registration or managed identity |
| `AZURE_TENANT_ID` | — | Entra: tenant ID |
| `AZURE_FEDERATED_TOKEN_FILE` | — | Entra workload identity: path of the projected service account token |
| `AZURE_CLIENT_SECRET` | — | Entra client secret. Ignored when `AZURE_FEDERATED_TOKEN_FILE` is set |
| `AZURE_AUTHORITY_HOST` | `https://login.microsoftonline.com/` | Entra authority, for sovereign clouds |
| `HTTP_PORT` | `80` | HTTP port inside the container |
| `HTTPS_PORT` | `8443` | HTTPS port inside the container |

## Authenticating to Azure DevOps

| Method | Use when | Variables |
|---|---|---|
| Personal Access Token | Anywhere; simplest | `AZURE_PAT`, or per repository in `repos.conf` |
| Entra workload identity | Kubernetes with a public OIDC issuer (e.g. AKS) — no secret at all | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE` |
| Entra client secret | Docker, or Kubernetes without workload identity | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET` |

**PAT** — needs **Code → Read & Write** on the repository.

**Entra** — the proxy exchanges its credential for an Azure DevOps access token, sends it as a
bearer header only to the Azure DevOps hosts in `repos.conf`, and refreshes it before it expires.
`repos.conf` lines need only the URL. The identity must be added to the Azure DevOps organization
with **Contribute** on the repository: with Read only, mirroring works but every push fails with
`TF401027 ... 'GenericContribute' permission`.

For workload identity you also need an Entra app registration or managed identity with a
federated credential for the proxy's service account (audience `api://AzureADTokenExchange`).
Complete examples: [`k8s/entra-workload-identity`](k8s/entra-workload-identity) and
[`k8s/entra-client-secret`](k8s/entra-client-secret).

## HTTPS

HTTPS is served on container port `8443`. On first start the proxy generates a self-signed
certificate (valid 10 years):

```bash
git -c http.sslVerify=false clone https://<repo>:<token>@localhost:7443/<repo>.git
```

To use your own certificate, mount `tls.crt` and `tls.key` into `/etc/git-proxy/tls/` (see the
commented lines in [`docker-compose.yml`](docker-compose.yml)).

## Kubernetes

[`k8s/`](k8s) is a kustomize base with one overlay per authentication method. The Deployment
lives in the base; each overlay only adds its credential.

| Path | Contents |
|---|---|
| [`k8s/base`](k8s/base) | Namespace, PVC, Service and Deployment, shared by all overlays |
| [`k8s/pat`](k8s/pat) | Adds `AZURE_PAT` from a Secret |
| [`k8s/entra-workload-identity`](k8s/entra-workload-identity) | Adds a ServiceAccount, the projected token and the workload identity variables |
| [`k8s/entra-client-secret`](k8s/entra-client-secret) | Adds the Entra variables and `AZURE_CLIENT_SECRET` from a Secret |
| [`k8s/components/network-policy`](k8s/components/network-policy) | Optional: admits traffic only from Grafana pods. Recommended with `GIT_PROXY_AUTH=none` |

```bash
# 1. Set AZURE_DEVOPS_URL (and the image tag, if needed) in k8s/base/deployment.yaml
# 2. Fill in the overlay's secret.yaml or <client-id>/<tenant-id> — see its kustomization.yaml
kubectl apply -k k8s/pat      # or k8s/entra-workload-identity, k8s/entra-client-secret
```

For several repositories, mount a `repos.conf` Secret outside `/etc/git-proxy` and point
`REPOS_CONF` at it. The proxy writes its certificate and Entra token to `/etc/git-proxy`, so that
directory must stay writable.

The Service is `ClusterIP`; add an Ingress or use `LoadBalancer` to expose it outside the cluster.

## Guides

- [Grafana Git Sync with Azure DevOps](docs/grafana.md) — sync dashboards between Grafana and an Azure DevOps repository through the proxy

## Troubleshooting

- **Verify protocol v2:** `GIT_TRACE_PACKET=1 git -C <repo> fetch 2>&1 | grep 'version 2'`
- **Logs:** `docker logs -f git-v2-proxy`, or `kubectl logs -n git-proxy deploy/git-proxy`
- **Push fails with `TF401027`:** the identity has Read but not Contribute on the repository
- **Shallow clones** (`git clone --depth 1`) are not supported yet and fail with `expected 'packfile', received 'shallow-info'`

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Please report security
issues privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
