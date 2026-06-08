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

- Docker + Docker Compose
- Azure DevOps Personal Access Token with **Code → Read & Write** scope per repo

## Setup

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

Set in `.env` or via `docker compose --env-file .env up`.

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
  --namespace grafana-horizon \
  --from-literal=AZURE_PAT=<your-azure-devops-pat>
```

The PAT needs **Code → Read** scope (add **Write** if you want push-back).

#### 2. Deploy the proxy

For a single repo you can skip `repos.conf` entirely and use env vars. Deploy to the **same namespace as Grafana** so the in-cluster DNS name resolves:

```yaml
# k8s/deployment.yaml (relevant snippet)
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

The proxy derives the local repo name from the URL — `Horizon-Dashboards` becomes `/Horizon-Dashboards.git`.

#### 3. Service

Deploy the Service in the same namespace:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: git-proxy
  namespace: grafana-horizon          # same namespace as Grafana
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
  Horizon-Dashboards     Horizon-Dashboards      <generated-token>
```

```bash
kubectl logs -n grafana-horizon deploy/git-proxy | grep -A5 '\[credentials\]'
```

The token is stable across restarts (stored in the git-repos volume).

#### 5. Configure Grafana

Use the in-cluster HTTP URL — no TLS needed for cluster-internal traffic:

```yaml
# Grafana dashboard provisioning (values.yaml extraObjects or ConfigMap)
apiVersion: 1
providers:
  - name: dashboards
    type: git
    options:
      url: http://git-proxy.grafana-horizon.svc.cluster.local/Horizon-Dashboards.git
      ref: main
      rootPath: dashboards/
      authType: basic
      username: Horizon-Dashboards      # repo name (from credentials table above)
      password: <generated-token>       # token from proxy logs
```

The URL pattern is always `http://git-proxy.<namespace>.svc.cluster.local/<repo-name>.git`.

For a trusted cert in Kubernetes, apply `k8s/tls-secret.yaml` and uncomment the TLS volume in `k8s/deployment.yaml`.

## Logs

```bash
docker logs -f git-v2-proxy
```

## Kubernetes

```bash
# 1. Fill in your repos in k8s/secret.yaml (the repos.conf key)
# 2. Update the image name in k8s/deployment.yaml

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/pvc.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

The service is `ClusterIP` by default. Add an Ingress or change to `LoadBalancer` to expose it outside the cluster.

## Docker Hub (CI)

The GitHub Actions workflow builds and pushes to Docker Hub on every push to `main`.

Add these secrets to your GitHub repo (`Settings → Secrets → Actions`):

| Secret | Description |
|---|---|
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token (not your password) |

Images are tagged `latest`, short SHA, and semver tags on releases.

## License

MIT — see [LICENSE](LICENSE)
