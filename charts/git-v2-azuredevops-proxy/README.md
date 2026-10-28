# git-v2-azuredevops-proxy

A Git Smart HTTP server with **protocol v2** in front of Azure DevOps, which only speaks protocol
v1. It mirrors your repositories, serves clones and fetches with protocol v2, and forwards pushes
to Azure DevOps — for example so that [Grafana Git Sync](https://github.com/Dominik-esb/git-v2-azuredevops-proxy/blob/main/docs/grafana.md)
can work with Azure DevOps.

Source and full documentation: <https://github.com/Dominik-esb/git-v2-azuredevops-proxy>

## Install

```bash
helm install git-proxy oci://ghcr.io/dominik-esb/charts/git-v2-azuredevops-proxy \
  --namespace git-proxy --create-namespace \
  --set 'repos[0]=https://dev.azure.com/<org>/<project>/_git/<repo>' \
  --set upstream.pat.value=<pat>
```

The release notes print the in-cluster URL and how to read the generated access tokens.

## Authentication to Azure DevOps

| `upstream.auth` | You provide |
|---|---|
| `pat` (default) | `upstream.pat.value`, or `upstream.pat.existingSecret` |
| `entraWorkloadIdentity` | `upstream.entra.clientId` and `tenantId`, plus a federated credential for `system:serviceaccount:<namespace>:<service account>` with audience `api://AzureADTokenExchange`. No secret at all. |
| `entraClientSecret` | `upstream.entra.clientId`, `tenantId` and `clientSecret.value` (or `clientSecret.existingSecret`) |

The identity needs **Contribute** on the repositories (a PAT: **Code → Read & Write**). With read
access only, mirroring works but every push fails with `TF401027`.

```yaml
# values.yaml — workload identity, several repositories
repos:
  - https://dev.azure.com/myorg/myproject/_git/grafana-dashboards
  - https://dev.azure.com/myorg/myproject/_git/alerting-rules
upstream:
  auth: entraWorkloadIdentity
  entra:
    clientId: 00000000-0000-0000-0000-000000000000
    tenantId: 00000000-0000-0000-0000-000000000000
```

## Exposing the proxy

Inside the cluster, clients use the Service: `http://<release>-git-v2-azuredevops-proxy.<namespace>.svc.cluster.local/<repo>.git`.

### Gateway API

Requires Gateway API v1.5 or later for ListenerSet.

**Attach to an existing Gateway listener** with an HTTPRoute:

```yaml
gateway:
  httpRoute:
    enabled: true
    parentRefs:
      - name: shared-gateway
        namespace: gateway-system
        sectionName: https
    hostnames:
      - git.example.com
    timeouts:
      request: 600s   # large clones and pushes can take minutes
```

**Bring your own listener with a ListenerSet.** The chart creates a ListenerSet with its own
hostname, port and TLS certificate, attached to a shared Gateway, and routes it to the proxy. The
platform team doesn't need to edit the Gateway for each application — it only has to allow
ListenerSets once:

```yaml
# on the shared Gateway (platform team, once)
spec:
  allowedListeners:
    namespaces:
      from: All        # or Same, or Selector with a namespace label selector
```

```yaml
# values.yaml
gateway:
  listenerSet:
    enabled: true
    parentRef:
      name: shared-gateway
      namespace: gateway-system
    listeners:
      - name: https
        hostname: git.example.com
        port: 443
        protocol: HTTPS
        tls:
          mode: Terminate
          certificateRefs:
            - name: git-proxy-tls   # a TLS Secret in the release namespace
```

### Ingress

`ingress.enabled: true` with the usual `className`, `hosts` and `tls` settings.

## Security

**Pod Security Standards:** the chart meets the **`restricted`** profile out of the box and is
tested in CI by installing every configuration into a namespace that enforces it:

```bash
kubectl label namespace git-proxy pod-security.kubernetes.io/enforce=restricted
```

The pod runs as uid/gid `10001` with `runAsNonRoot`, all capabilities dropped,
`allowPrivilegeEscalation: false`, a read-only root filesystem and the `RuntimeDefault` seccomp
profile. The service account token is not mounted.

**Access:** with the default `proxyAuth: basic`, each repository gets its own generated access
token (user name = repository name), printed to the pod log. `proxyAuth: none` turns that off —
anyone who can reach the Service can then push to Azure DevOps as the proxy's identity, so only
use it with `networkPolicy.enabled: true`, which by default only admits Grafana pods.

## Values

| Key | Default | Description |
|---|---|---|
| `repos` | `[]` | **Required.** Azure DevOps repository URLs; each is served at `/<repo>.git` |
| `syncInterval` | `60` | Seconds between background fetches |
| `proxyAuth` | `basic` | `basic` or `none` (see Security) |
| `statusPage.enabled` | `true` | Read-only status page at `/` |
| `upstream.auth` | `pat` | `pat`, `entraWorkloadIdentity` or `entraClientSecret` |
| `upstream.pat.value` / `.existingSecret` / `.existingSecretKey` | `""` / `""` / `AZURE_PAT` | PAT, or a Secret holding it |
| `upstream.entra.clientId` / `.tenantId` | `""` | Entra application (client) and tenant ID |
| `upstream.entra.authorityHost` | `""` | Only for sovereign clouds |
| `upstream.entra.clientSecret.value` / `.existingSecret` / `.existingSecretKey` | `""` / `""` / `AZURE_CLIENT_SECRET` | Client secret, or a Secret holding it |
| `upstream.entra.workloadIdentity.audience` | `api://AzureADTokenExchange` | Audience of the projected token |
| `image.repository` / `.tag` / `.pullPolicy` | `dominikesb/git-v2-azuredevops-proxy` / appVersion / `IfNotPresent` | Image |
| `serviceAccount.create` / `.name` / `.annotations` | `true` / `""` / `{}` | Service account |
| `service.type` / `.port` / `.httpsPort` | `ClusterIP` / `80` / `8443` | Service |
| `gateway.httpRoute.*` | disabled | HTTPRoute: `parentRefs`, `hostnames`, `timeouts`, `annotations` |
| `gateway.listenerSet.*` | disabled | ListenerSet: `parentRef`, `listeners`, `annotations` |
| `ingress.*` | disabled | Ingress: `className`, `annotations`, `hosts`, `tls` |
| `tls.existingSecret` | `""` | TLS Secret for the proxy's own HTTPS port (self-signed otherwise) |
| `persistence.enabled` / `.size` / `.storageClass` / `.existingClaim` | `true` / `10Gi` / `""` / `""` | Volume for the mirrors and access tokens; kept on uninstall |
| `networkPolicy.enabled` / `.from` | `false` / Grafana pods | Restrict who can reach the proxy |
| `tmpSizeLimit` | `1Gi` | Size limit of `/tmp`, where push uploads are buffered |
| `resources`, `podSecurityContext`, `securityContext` | see `values.yaml` | Restricted-compliant defaults |
| `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`, `podLabels` | empty | Scheduling and metadata |
| `extraEnv`, `extraVolumes`, `extraVolumeMounts` | `[]` | Escape hatches |

All values are validated by `values.schema.json`.
