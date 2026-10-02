# Git Protocol v2 Proxy for Azure DevOps

A Docker container that acts as a local Git Smart HTTP server with **protocol v2** support, proxying Azure DevOps repositories that only speak protocol v1.

## Why

Azure DevOps does not support Git HTTP protocol v2. Some tools (CI systems, IDEs, custom tooling) require or benefit from v2's more efficient ref negotiation. This container sits in between:

```
your client (v2)  →  container (v1↔v2 bridge)  →  Azure DevOps (v1)
```

## How it works

| Direction | Trigger | Mechanism |
|---|---|---|
| Azure DevOps → local | Every `SYNC_INTERVAL` seconds | Background `git fetch --mirror` |
| Local → Azure DevOps | On every client push | `post-receive` hook forwards push upstream |

Clones and fetches are served locally at full speed with protocol v2. Pushes are transparently forwarded to Azure DevOps in real time.

## Requirements

- Docker Compose
- An Azure DevOps Personal Access Token with **Code → Read & Write** scope per repo, or a Microsoft Entra identity (workload identity on Kubernetes, or a client secret) — see [Authenticating to Azure DevOps](#authenticating-to-azure-devops)

## Quick Setup

```bash
# 1. Create your repos config (contains PATs — keep it secret, never commit it)
cp repos.conf.example repos.conf
# edit repos.conf and add your repos

# 2. Start
docker compose up -d --build
```

## repos.conf

One repo per line — the local URL is auto-derived from the Azure DevOps repo name:

```
# Format: <AZURE_DEVOPS_URL> <PAT>
https://dev.azure.com/myorg/myproject/_git/repo1  pat1here
https://dev.azure.com/myorg/myproject/_git/repo2  pat2here
```

`repo1` → `http://localhost:7080/repo1.git`

## Configuration

| Variable | Default | Description |
|---|---|---|
| `SYNC_INTERVAL` | `60` | Seconds between background fetches from Azure DevOps |
| `AZURE_DEVOPS_URL` | — | Single-repo mode: the repo URL, used when no `repos.conf` is mounted |
| `AZURE_PAT` | — | Single-repo mode: the PAT for `AZURE_DEVOPS_URL` |
| `REPOS_CONF` | `/etc/git-proxy/repos.conf` | Path of the multi-repo config |
| `GIT_PROXY_AUTH` | `basic` | `basic`: a generated token per repo, printed to the log. `none`: no auth on the git endpoints — only when something else (e.g. a Kubernetes NetworkPolicy) restricts who can reach the proxy |
| `AZURE_CLIENT_ID` | — | Entra: client ID of the app registration or managed identity |
| `AZURE_TENANT_ID` | — | Entra: tenant ID |
| `AZURE_FEDERATED_TOKEN_FILE` | — | Entra workload identity: path of the projected service account token |
| `AZURE_CLIENT_SECRET` | — | Entra client secret: the app registration's secret. Ignored when `AZURE_FEDERATED_TOKEN_FILE` is set |
| `AZURE_AUTHORITY_HOST` | `https://login.microsoftonline.com/` | Entra: authority, for sovereign clouds |

Set in `.env` or via `docker compose --env-file .env up`.

## Authenticating to Azure DevOps

The proxy supports three ways to authenticate to Azure DevOps.

**Personal Access Token** — the default. A PAT with **Code → Read & Write**, either per repo in
`repos.conf` or as `AZURE_PAT`.

**Microsoft Entra workload identity** — no PAT and no secret, for Kubernetes. Set
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_FEDERATED_TOKEN_FILE` (the same variable names
the Azure Workload Identity webhook injects on AKS). The proxy exchanges the projected service
account token for an Azure DevOps access token, sends it as a bearer header on every fetch and
forwarded push, and refreshes it before it expires. In this mode `repos.conf` lines need only
the URL. It needs:

- a publicly reachable OIDC issuer for the cluster
- an Entra app registration or managed identity with a federated credential for the proxy's
  service account (audience `api://AzureADTokenExchange`)
- that identity added to the Azure DevOps organization with **Contribute** on the repo. Read is
  enough to mirror, but every push then fails with `TF401027 ... 'GenericContribute' permission`.

See [`k8s/entra-workload-identity`](k8s/entra-workload-identity) for a complete example.

**Microsoft Entra client secret** — for Docker Compose or any host without workload identity.
Set `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_CLIENT_SECRET` of an Entra app registration.
The proxy gets and refreshes its Azure DevOps access token the same way as with workload
identity, and `repos.conf` lines need only the URL. Add the app registration to the Azure DevOps
organization with **Contribute** on the repo. Secrets expire, so rotate it before its end date.
See [`k8s/entra-client-secret`](k8s/entra-client-secret) for a Kubernetes example.

## Usage

```bash
# Clone
git clone http://localhost:7080/<repo-name>.git

# Force protocol v2 explicitly
git -c protocol.version=2 clone http://localhost:7080/<repo-name>.git

# Push — forwarded to Azure DevOps automatically
git push
```

## Verify protocol v2

```bash
GIT_TRACE_PACKET=1 git -C <repo> fetch 2>&1 | head -5
# Look for: packet: ... version 2
```

## HTTPS

HTTPS is enabled by default on port `7443`. On first start the container **auto-generates a self-signed certificate** (valid 10 years) — no config needed.

```bash
git clone https://localhost:7443/<repo-name>.git
# self-signed: add -c http.sslVerify=false if your client rejects it
```

### Bring your own certificate

Mount `tls.crt` and `tls.key` to override the self-signed cert:

```yaml
# docker-compose.yml — uncomment the tls lines
volumes:
  - ./tls/tls.crt:/etc/git-proxy/tls/tls.crt:ro
  - ./tls/tls.key:/etc/git-proxy/tls/tls.key:ro
```

### Grafana Git provisioning (Azure DevOps on Kubernetes)

This is a complete example of running the proxy in the same namespace as Grafana so that Grafana's built-in Git provisioning (Pure Git / Git v2 Smart HTTP) can sync dashboards from Azure DevOps.

#### 1. Create the PAT secret

```bash
kubectl create secret generic git-proxy-credentials \
  --namespace grafana \
  --from-literal=AZURE_PAT=<your-azure-devops-pat>
```

The PAT needs **Code → Read** scope (add **Write** if you want push-back).

#### 2. Deploy the proxy

For a single repo you can skip `repos.conf` entirely and use env vars. Deploy to the **same namespace as Grafana** so the in-cluster DNS name resolves:

```yaml
# k8s/pat/deployment.yaml (relevant snippet)
env:
  - name: AZURE_DEVOPS_URL
    value: "https://dev.azure.com/<org>/<project>/_git/<repo>"
  - name: SYNC_INTERVAL
    value: "60"
  - name: AZURE_PAT
    valueFrom:
      secretKeyRef:
        name: git-proxy-credentials
        key: AZURE_PAT
```

The proxy derives the local repo name from the URL — `grafana-dashboards` becomes `/grafana-dashboards.git`.

#### 3. Service

Deploy the Service in the same namespace:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: git-proxy
  namespace: grafana          # same namespace as Grafana
  annotations:
    argocd.argoproj.io/sync-options: Replace=true   # avoids SSA port-name conflicts
spec:
  type: ClusterIP
  selector:
    app: git-proxy
  ports:
    - name: http
      port: 80
      targetPort: 80
      protocol: TCP
```

> **ArgoCD note:** the `Replace=true` annotation is required when managing this Service with ArgoCD server-side apply. Without it, a port rename between deploys leaves a stale entry that causes a duplicate port-name validation error.

#### 4. Get the generated access token

On first start the proxy generates a random token per repo and prints it to stdout:

```
[credentials] Grafana Git provisioning credentials:

  REPO                   USERNAME                TOKEN
  ----                   --------                -----
  grafana-dashboards     grafana-dashboards      <generated-token>
```

```bash
kubectl logs -n grafana deploy/git-proxy | grep -A5 '\[credentials\]'
```

The token is stable across restarts (stored in the git-repos volume).

![Container logs showing init sequence, credentials table, and live sync output](docs/images/container-logs.png)

#### 5. Configure Grafana

Use the in-cluster HTTP URL — no TLS needed for cluster-internal traffic:

```yaml
# Grafana dashboard provisioning (values.yaml extraObjects or ConfigMap)
apiVersion: 1
providers:
  - name: dashboards
    type: git
    options:
      url: http://git-proxy.grafana.svc.cluster.local/grafana-dashboards.git
      ref: main
      rootPath: dashboards/
      authType: basic
      username: grafana-dashboards      # repo name (from credentials table above)
      password: <generated-token>       # token from proxy logs
```

The URL pattern is always `http://git-proxy.<namespace>.svc.cluster.local/<repo-name>.git`.

In the Grafana UI (**Administration → Provisioning → Add repository**), set type **Pure Git** and fill in the URL, username, and token:

![Grafana Pure Git provisioning config pointing at the proxy](docs/images/grafana-provisioning-config.png)

For a trusted cert in Kubernetes, apply `k8s/tls-secret.yaml` and uncomment the TLS volume in your overlay's `deployment.yaml`.

#### Result

Once connected, saving a dashboard in Grafana creates a commit in Azure DevOps automatically. The proxy syncs bidirectionally — changes pushed to DevOps appear in Grafana, and saves in Grafana push back through the proxy to DevOps.

**Azure DevOps repo — dashboard JSON committed by Grafana:**

![Azure DevOps repo showing test.json committed by Grafana](docs/images/devops-repo-dashboard.png)

**Azure DevOps commit history — commit authored by Grafana:**

![Azure DevOps commits list showing Save dashboard commit from Grafana](docs/images/devops-commit-by-grafana.png)

## Logs

```bash
docker logs -f git-v2-proxy
```

## Kubernetes

[`k8s/`](k8s) is a kustomize base with one overlay per way of authenticating to Azure DevOps:

| | |
|---|---|
| [`k8s/base`](k8s/base) | Namespace, PVC and Service, shared by all overlays |
| [`k8s/pat`](k8s/pat) | Deployment plus a Secret with `AZURE_PAT` |
| [`k8s/entra-workload-identity`](k8s/entra-workload-identity) | Deployment with the projected token and `AZURE_*` workload identity variables, plus a ServiceAccount |
| [`k8s/entra-client-secret`](k8s/entra-client-secret) | Deployment with the `AZURE_*` variables, plus a Secret with `AZURE_CLIENT_SECRET` |

```bash
# 1. Set the image and AZURE_DEVOPS_URL in the overlay's deployment.yaml
# 2. PAT: fill in k8s/pat/secret.yaml.  Entra: fill in <client-id> and <tenant-id> in
#    k8s/entra-workload-identity/deployment.yaml and create the federated credential described in k8s/entra-workload-identity/kustomization.yaml.
#    Entra client secret: fill in k8s/entra-client-secret/deployment.yaml and secret.yaml.
kubectl apply -k k8s/pat      # or: k8s/entra-workload-identity, k8s/entra-client-secret
```

For several repos, mount a `repos.conf` (a Secret) and point `REPOS_CONF` at it instead of
setting `AZURE_DEVOPS_URL`. Mount it outside `/etc/git-proxy` — the proxy writes its generated
TLS certificate (and, with Entra, its token) there, so that directory must stay writable.

The service is `ClusterIP` by default. Add an Ingress or change to `LoadBalancer` to expose it outside the cluster.

## Releases

Pull requests and pushes to `main` only **build** the image (multi-arch) and run the smoke test. Nothing is pushed to Docker Hub.
An image is published only when a version tag is pushed:

```bash
git tag v1.2.3
git push origin v1.2.3
```

The [Release workflow](.github/workflows/release.yml) then runs the smoke test, pushes `1.2.3`, `1.2`, `1` and `latest` to Docker Hub (multi-arch, with SBOM and provenance), and creates a GitHub Release with generated notes.

## License

MIT — see [LICENSE](LICENSE)
