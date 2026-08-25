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

```bash
git clone https://github.com/GuhaTek/velai-oss.git
cd velai-oss
kubectl create namespace velai
```

## 2. Create the required Secrets

**Licence** (from your credential bundle):
```bash
kubectl -n velai create secret generic velai-license \
  --from-literal=VELAI_TENANT_SLUG=<your-slug> \
  --from-literal=VELAI_LICENSE_URL=<your-licence-url> \
  --from-file=VELAI_LICENSE_KEY=./<slug>-tenant.key \
  --from-file=VELAI_LICENSE_CA=./<slug>-velai-ca.crt
```

**Admin Console** login + session (password hash is in your bundle; session secret is any 32+ random chars):
```bash
kubectl -n velai create secret generic velai-admin-secrets \
  --from-literal=ADMIN_USERNAME=velaiadmin \
  --from-literal=ADMIN_PASSWORD_HASH='<scrypt hash from your bundle>' \
  --from-literal=SESSION_SECRET="$(openssl rand -hex 24)"
# For SSO, also: --from-literal=OIDC_CLIENT_SECRET='<your IdP client secret>'
```

## 3. Images & pull access

The VelAI images are private. Set `image.registry` to the registry you were granted
access to and provide a pull secret:

```bash
kubectl -n velai create secret docker-registry velai-pull \
  --docker-server=<registry> --docker-username=<user> --docker-password=<token>
```

```yaml
# my-values.yaml
image:
  registry: "<registry>/velai"
imagePullSecrets:
  - name: velai-pull
adminConsole:
  image: "admin-console:<tag>"
  ingress:
    enabled: true
    className: "nginx"
    host: "velai.your-company.com"
orchestrator: { image: "orchestrator:<tag>" }
oncall:       { image: "oncall:<tag>" }
```

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
helm install velai ./charts/velai -n velai -f my-values.yaml
kubectl -n velai get pods -w
```

Open the console (Ingress host, or `kubectl -n velai port-forward svc/velai-admin-console 8080:8080`).
The console shows agent health + your licence status, and generates the commands to add
more agents.

## Key values

| Key | Default | Notes |
|---|---|---|
| `image.registry` | `REGISTRY.EXAMPLE.COM/velai` | your pull registry |
| `imagePullSecrets` | `[]` | docker-registry secret name(s) |
| `license.existingSecret` | `velai-license` | licence bundle secret |
| `license.clusterUid` | `""` | set to bind Guard 1 to this cluster (else read in-cluster) |
| `adminConsole.oidc.*` / `allowedDomain` | `""` | generic OIDC SSO (Google/JumpCloud/Okta) |
| `adminConsole.ingress.*` | disabled | expose the console |
| `postgresql.enabled` | `true` | in-cluster DB; set `externalUrl` to use your own |
| `redis.enabled` | `true` | in-cluster Redis |

Full list: [`values.yaml`](values.yaml).

## Troubleshooting / gotchas

- **Overriding an image tag** — the image is composed as `image.registry` + `<component>.image`, so override the component key, e.g. `--set adminConsole.image=velai-admin-console:<tag>` (also `orchestrator.image`, `oncall.image`). There is **no** `images.adminConsole` value — setting it is silently ignored and the old tag stays.
- **Changing a ServiceAccount's IRSA role ARN** (`serviceAccount.annotations.eks.amazonaws.com/role-arn`, or the same under `external-secrets.serviceAccount.annotations`) does **not** restart the pods. IRSA injects `AWS_ROLE_ARN` at pod admission, so a running pod keeps the old value — `kubectl -n <ns> rollout restart deploy/<name>` after the change. Symptom of a stale/placeholder ARN: `botocore ParamValidationError: Invalid length for parameter RoleArn` in the pod logs, and AWS-backed pages (Admin Configuration, Add-an-Agent) failing.
- **`helm upgrade --reuse-values`** carries the previous release's values but can drop keys across chart-version changes (e.g. `externalSecrets.paramsStore`/`secretsStore` rendering as `null`). For anything non-trivial, keep your overrides in a values file and pass `-f my-values.yaml` instead.
- **AWS secret backend** — the chart creates the ClusterSecretStores for azure/gcp/oci/vault, but **not** for AWS: create `aws-parameter-store` + `aws-secrets-manager` ClusterSecretStores yourself (pointed at the ESO controller's IRSA SA), and the console + ESO SAs need read/write on `ssm:/velai/*` and `secretsmanager:velai/*`.

## Uninstall

```bash
helm uninstall velai -n velai
# the generated Postgres password secret is kept by design; delete manually if wanted:
kubectl -n velai delete secret velai-postgresql
```
