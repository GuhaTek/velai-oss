# VelAI Helm chart

Installs the VelAI **Admin Console + Orchestrator + On-call agent** (plus in-cluster
Redis and PostgreSQL) into your Kubernetes cluster. The chart contains **no secrets
and no application code** — only Kubernetes manifests. You provide the container
images and two pre-created Secrets.

## Prerequisites

- Kubernetes 1.24+ and Helm 3.8+
- A VelAI **licence bundle** (issued to you — tenant slug, licence URL, tenant key, CA cert)
- **Pull access** to the VelAI images (see "Images & pull access" below)

## 1. Get the chart

The chart is published to a Helm repository (always pin `--version`):

```bash
helm repo add velai https://guhatek.github.io/velai-oss
helm repo update
helm search repo velai/velai --versions
kubectl create namespace velai
```

### Verifying the chart

Every release is signed (a `.prov` provenance file next to the chart) with the key
**GuhaTek VelAI Charts**, fingerprint `11E1 246D D4B6 419D DD06 68DA 9B45 F52D 39E4 B069`
([`pgp/velai-charts.asc`](../../pgp/velai-charts.asc)). Helm reads a legacy binary keyring:

```bash
curl -fsSL https://raw.githubusercontent.com/GuhaTek/velai-oss/main/pgp/velai-charts.asc | gpg --dearmor > velai-charts.gpg
helm install velai velai/velai --version <chart-version> --verify --keyring ./velai-charts.gpg ...
```

`--verify` refuses to install a chart whose signature or SHA-256 doesn't match.

## 2. Create the required Secrets

**Licence** (from your credential bundle):
```bash
kubectl -n velai create secret generic velai-license \
  --from-literal=VELAI_TENANT_SLUG=<your-slug> \
  --from-literal=VELAI_LICENSE_URL=<your-licence-url> \
  --from-file=VELAI_LICENSE_KEY=./<slug>-tenant.key \
  --from-file=VELAI_LICENSE_CA=./<slug>-velai-ca.crt \
  --from-literal=VELAI_SEAL_KEY='<seal key from your bundle>'   # only for per-tenant images
```
`VELAI_SEAL_KEY` is needed only if VelAI built agent images just for you
(`velai-tenant/<slug>/...`); the standard images don't use it.

**Admin Console** login + session (password hash is in your bundle; session secret is any 32+ random chars):
```bash
kubectl -n velai create secret generic velai-admin-secrets \
  --from-literal=ADMIN_USERNAME=velaiadmin \
  --from-literal=ADMIN_PASSWORD_HASH='<scrypt hash from your bundle>' \
  --from-literal=SESSION_SECRET="$(openssl rand -hex 24)"
# For SSO, also: --from-literal=OIDC_CLIENT_SECRET='<your IdP client secret>'
```

## 3. Images & pull access

The VelAI images are private and come from `registry.guhatek.com` (the chart default for
`image.registry`; change it only if you mirror the images). Provide a pull secret:

```bash
kubectl -n velai create secret docker-registry velai-pull \
  --docker-server=registry.guhatek.com --docker-username=<user> --docker-password=<token>
```

```yaml
# my-values.yaml
imagePullSecrets:
  - name: velai-pull
adminConsole:
  image: "velai-shared/admin-console:<version>"
  ingress:
    enabled: true
    className: "nginx"
    host: "velai.your-company.com"
# Protected agent images (see below):
orchestrator:
  image: "velai-shared/orchestrator:<version>"
  protected: { enabled: true }
oncall:
  image: "velai-shared/oncall:<version>"
  protected: { enabled: true }
license:
  clusterUid: "<kube-system namespace UID>"
```

### Protected agent images

The Orchestrator and On-call images are **protected**: their compiled modules are sealed, and
the image's loader unseals them at start into a RAM-backed tmpfs, so they never touch disk.
With `<agent>.protected.enabled=true` the chart mounts that tmpfs.

At start the loader requests the image's key from the VelAI licence server, authenticating
with your licence Secret. The key is issued only while your licence is valid and is bound to
your cluster (the kube-system namespace UID), so a copied image won't start elsewhere. A new
pod therefore needs the licence server reachable; container restarts inside a running pod
don't. If VelAI built images just for your cluster (`velai-tenant/<slug>/...`), those use
`VELAI_SEAL_KEY` from the licence Secret instead and need no licence-server call at start.
Use the same `<version>` for every image.

### Automatic pull-secret refresh (recommended)

Instead of creating `velai-pull` by hand (its token expires), let the Admin Console
keep it fresh: it fetches short-lived registry credentials from the VelAI licence
server on a timer — returned **only while your licence is valid** — and rewrites the
secret. No long-lived token lives in your cluster, and a lapsed licence stops new
pulls automatically.

```yaml
pullRefresh:
  enabled: true
  secretName: velai-pull    # must match imagePullSecrets[].name
  intervalHours: 6
imagePullSecrets:
  - name: velai-pull
```

The chart grants the console tightly-scoped RBAC (create the secret, then get/patch
only that one secret). You don't pre-create `velai-pull` in this mode.

> **On AWS/EKS and prefer no token at all?** Ask VelAI to enable a **cross-account
> ECR repository policy** for your AWS account id, then your nodes/IRSA pull directly
> (set `serviceAccount.annotations` for the IRSA role and leave `imagePullSecrets`
> empty). Most hands-off, but AWS-only.

## 4. Install

```bash
helm install velai velai/velai --version <chart-version> -n velai -f my-values.yaml   # add --verify --keyring ./velai-charts.gpg
kubectl -n velai get pods -w
```

Open the console (Ingress host, or `kubectl -n velai port-forward svc/velai-admin-console 8080:8080`).
The console shows agent health + your licence status, and generates the commands to add
more agents.

## 5. MCP servers (optional)

The built-in MCP servers (Kubernetes, Prometheus, New Relic, OpenSearch, GitLab) are the tools
your RCA and conversation agents call. They are off by default; enable each one on your existing
release. The Admin Console generates this command for you under **Integrations → MCP**:

```bash
helm repo update velai
helm upgrade velai velai/velai --version <chart-version> -n velai --reset-then-reuse-values \
  --set mcp.prometheus.enabled=true \
  --set mcp.prometheus.image=velai-shared/mcp-prometheus:<version>
kubectl -n velai rollout status deploy/velai-mcp-prometheus
```

- **Use `--reset-then-reuse-values`** (Helm 3.14+), not `--reuse-values`. Upgrading from a chart
  version without MCP support with `--reuse-values` skips the new `mcp` defaults; the chart then
  stops with an error that says so.
- **No registry to set.** The image is `image.registry` (from your install) + `mcp.<name>.image`.
- **Credentials** come from the Admin Console. Add the connection under Integrations, bind it to
  the RCA agent, and set `mcp.settingsScope` to that agent's scope: `rca` (the default) or
  `agent-instances/rca/<instance>` for a named instance. This needs `secretBackend` and
  `externalSecrets.enabled=true`. Each server receives only its own keys from that scope, never
  the LLM or Slack credentials stored beside them. Environment is read at start, so after changing
  a credential run `kubectl -n velai rollout restart deploy/velai-mcp-<name>`.
- **The Kubernetes server needs a cluster admin to install.** It reads pods, events, logs and
  workloads across all namespaces (read-only; never Secrets or ConfigMaps), so the chart creates
  a ClusterRole and ClusterRoleBinding. Someone with admin rights on the `velai` namespace only
  gets `cannot get resource "clusterroles"` from Helm. It authenticates with its own
  ServiceAccount, so no kubeconfig is needed for the cluster it runs in.
- **Caller token.** The servers refuse tool calls without `MCP_AUTH_TOKEN`, which the chart
  generates into the `velai-internal` Secret next to `INTERNAL_API_TOKEN`. Give your RCA agent the
  same value. Without it the servers still answer `/health`.
- **Health.** Each enabled server appears on the console dashboard under **MCP health**: green
  when up and configured, amber "Degraded" when it runs but its credentials are missing or wrong.

## Key values

| Key | Default | Notes |
|---|---|---|
| `image.registry` | `registry.guhatek.com` | the VelAI registry host (change only to mirror) |
| `imagePullSecrets` | `[]` | docker-registry secret name(s) |
| `license.existingSecret` | `velai-license` | licence bundle secret |
| `license.clusterUid` | `""` | set to bind Guard 1 to this cluster (else read in-cluster) |
| `orchestrator.protected.enabled` / `oncall.protected.enabled` | `false` | RAM tmpfs for protected (sealed) agent images |
| `internalToken.existingSecret` | `""` | agents' shared internal + MCP tokens (`INTERNAL_API_TOKEN`, `MCP_AUTH_TOKEN`); generated + kept when empty |
| `mcp.<name>.enabled` / `mcp.<name>.image` | `false` / `velai-shared/mcp-<name>:latest` | built-in MCP servers: `kubernetes`, `prometheus`, `newrelic`, `opensearch`, `gitlab` |
| `mcp.settingsScope` | `rca` | console scope the MCP credentials are synced from |
| `mcp.protected.enabled` | `true` | the published MCP images are protected (sealed) builds |
| `adminConsole.oidc.*` / `allowedDomain` | `""` | generic OIDC SSO (Google/JumpCloud/Okta) |
| `adminConsole.oidc.roleGroups` | `""` | IdP group → console role, e.g. `velai-admins=admin,velai-ops=operator,velai-viewers=member` (highest wins; a Users-page assignment overrides) |
| `adminConsole.ingress.*` | disabled | expose the console |
| `postgresql.enabled` | `true` | in-cluster DB; set `externalUrl` to use your own |
| `redis.enabled` | `true` | in-cluster Redis |

Full list: [`values.yaml`](values.yaml).

## Troubleshooting / gotchas

- **Overriding an image tag** — the image is composed as `image.registry` + `<component>.image`, so override the component key, e.g. `--set adminConsole.image=velai-shared/admin-console:<version>` (also `orchestrator.image`, `oncall.image`). There is **no** `images.adminConsole` value — setting it is silently ignored and the old tag stays.
- **Changing a ServiceAccount's IRSA role ARN** (`serviceAccount.annotations.eks.amazonaws.com/role-arn`, or the same under `external-secrets.serviceAccount.annotations`) does **not** restart the pods. IRSA injects `AWS_ROLE_ARN` at pod admission, so a running pod keeps the old value — `kubectl -n <ns> rollout restart deploy/<name>` after the change. Symptom of a stale/placeholder ARN: `botocore ParamValidationError: Invalid length for parameter RoleArn` in the pod logs, and AWS-backed pages (Admin Configuration, Add-an-Agent) failing.
- **`helm upgrade --reuse-values`** carries the previous release's values but can drop keys across chart-version changes (e.g. `externalSecrets.paramsStore`/`secretsStore` rendering as `null`). For anything non-trivial, keep your overrides in a values file and pass `-f my-values.yaml` instead.
- **AWS secret backend** — the chart creates the ClusterSecretStores for azure/gcp/oci/vault, but **not** for AWS: create `aws-parameter-store` + `aws-secrets-manager` ClusterSecretStores yourself (pointed at the ESO controller's IRSA SA), and the console + ESO SAs need read/write on `ssm:/velai/*` and `secretsmanager:velai/*`.

## Uninstall

```bash
helm uninstall velai -n velai
# the generated Postgres password and internal token secrets are kept by design; delete manually if wanted:
kubectl -n velai delete secret velai-postgresql velai-internal
```
