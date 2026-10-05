{{- define "velai.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "velai.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s" (include "velai.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "velai.labels" -}}
app.kubernetes.io/name: {{ include "velai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "velai.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "velai.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "velai.image" -}}
{{- printf "%s/%s" (.registry | trimSuffix "/") .image -}}
{{- end -}}

{{/* Common env shared by every agent: licence + cluster binding. */}}
{{- define "velai.licenseEnv" -}}
{{- if .Values.license.clusterUid }}
- name: VELAI_CLUSTER_UID
  value: {{ .Values.license.clusterUid | quote }}
{{- end }}
{{- end -}}

{{/* VELAI_AGENT_VERSION, reported in licence check-ins (OneGT's version column): the image tag,
     e.g. velai-shared/orchestrator:0.1.535 -> 0.1.535. Images are reused byte-for-byte across
     releases, so the version can't be baked in; the tag is what's actually running. Omitted
     for a digest-pinned or untagged ref. Call with the component's image value. */}}
{{- define "velai.versionEnv" -}}
{{- $ref := toString . -}}
{{- $last := last (splitList "/" $ref) -}}
{{- if and (not (contains "@" $ref)) (contains ":" $last) }}
- name: VELAI_AGENT_VERSION
  value: {{ last (splitList ":" $last) | quote }}
{{- end }}
{{- end -}}

{{/* Secret-backend env for the Admin Console (which WRITES config to the backend). SECRET_BACKEND
     plus the non-secret connection params for the chosen provider. Blank backend => only
     SECRET_BACKEND="" so the console starts unconfigured. */}}
{{- define "velai.secretBackendEnv" -}}
- name: SECRET_BACKEND
  value: {{ .Values.secretBackend | quote }}
- name: SETTINGS_PREFIX
  value: {{ .Values.externalSecrets.prefix | quote }}
{{- if eq .Values.secretBackend "aws" }}
{{- if .Values.aws.region }}
- name: AWS_REGION
  value: {{ .Values.aws.region | quote }}
{{- end }}
{{- else if eq .Values.secretBackend "vault" }}
- name: VAULT_ADDR
  value: {{ .Values.vault.addr | quote }}
- name: VAULT_MOUNT
  value: {{ .Values.vault.mount | quote }}
- name: VAULT_K8S_ROLE
  value: {{ .Values.vault.k8sRole | quote }}
- name: VAULT_K8S_AUTH_PATH
  value: {{ .Values.vault.k8sAuthPath | quote }}
{{- else if eq .Values.secretBackend "azure" }}
- name: AZURE_VAULT_URL
  value: {{ .Values.azure.vaultUrl | quote }}
{{- else if eq .Values.secretBackend "gcp" }}
- name: GCP_PROJECT
  value: {{ .Values.gcp.project | quote }}
{{- else if eq .Values.secretBackend "oci" }}
- name: OCI_AUTH
  value: {{ .Values.oci.auth | quote }}
- name: OCI_REGION
  value: {{ .Values.oci.region | quote }}
- name: OCI_VAULT_ID
  value: {{ .Values.oci.vault | quote }}
- name: OCI_COMPARTMENT_ID
  value: {{ .Values.oci.compartment | quote }}
- name: OCI_KEY_ID
  value: {{ .Values.oci.key | quote }}
{{- end }}
{{- end -}}

{{/* Per-agent config envFrom: the Secret(s) ESO syncs from the backend for this agent. Call with
     (dict "root" $ "agent" "<key>"). No-op unless externalSecrets is enabled. */}}
{{- define "velai.agentConfigEnvFrom" -}}
{{- $root := .root -}}
{{- $agent := .agent -}}
{{- if $root.Values.externalSecrets.enabled -}}
{{- $full := include "velai.fullname" $root -}}
- secretRef:
    name: {{ $full }}-{{ $agent }}-secrets
    optional: true
{{- if eq $root.Values.secretBackend "aws" }}
- secretRef:
    name: {{ $full }}-{{ $agent }}-params
    optional: true
{{- end }}
{{- end -}}
{{- end -}}

{{/* envFrom sources shared by every agent (all optional so the chart installs cleanly). */}}
{{- define "velai.commonEnvFrom" -}}
- secretRef:
    name: {{ .Values.license.existingSecret | quote }}
    optional: true
{{- if .Values.agentConfig.existingSecret }}
- secretRef:
    name: {{ .Values.agentConfig.existingSecret | quote }}
    optional: true
{{- end }}
{{- end -}}

{{/* INTERNAL_API_TOKEN for the Console, Orchestrator and On-call agent (see internal-token.yaml). */}}
{{- define "velai.internalTokenEnv" -}}
- name: INTERNAL_API_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .Values.internalToken.existingSecret | default (printf "%s-internal" (include "velai.fullname" .)) | quote }}
      key: INTERNAL_API_TOKEN
{{- end -}}

{{/* Protected image wiring for an agent (call with (dict "p" <agent>.protected)): the loader
     unseals the compiled modules into this RAM-backed, exec-capable tmpfs. */}}
{{- define "velai.protectEnv" -}}
{{- if .p.enabled }}
- name: VELAI_PROTECT_TMPDIR
  value: /var/velai-mods
{{- end }}
{{- end -}}
{{- define "velai.protectMount" -}}
{{- if .p.enabled }}
volumeMounts:
  - name: velai-mods
    mountPath: /var/velai-mods
{{- end }}
{{- end -}}
{{- define "velai.protectVolume" -}}
{{- if .p.enabled }}
volumes:
  - name: velai-mods
    emptyDir:
      medium: Memory
      sizeLimit: {{ .p.tmpfsSize | quote }}
{{- end }}
{{- end -}}

{{/* Built-in MCP servers, in display order, with the exact keys each one reads from the settings
     scope: `params` are plain settings, `secrets` secret values. Each pod gets ONLY its own keys
     (per-key secretKeyRef), never the whole scope — which also holds LLM/Slack credentials. Adding
     a field to an integration in the Admin Console means adding its key here too. */}}
{{- define "velai.mcpCatalog" -}}
kubernetes:
  params:  [K8S_AUTH_METHOD, K8S_CONTEXT, K8S_API_SERVER]
  secrets: [KUBECONFIG_CONTENT, K8S_TOKEN, K8S_CA_CERT]
prometheus:
  params:  [PROMETHEUS_URL, PROM_AUTH_METHOD, PROM_USERNAME, PROM_OAUTH_CLIENT_ID, PROM_OAUTH_TOKEN_URL, PROM_OAUTH_SCOPES, PROM_AWS_ACCESS_KEY_ID, PROM_AWS_REGION]
  secrets: [PROM_PASSWORD, PROM_BEARER_TOKEN, PROM_OAUTH_CLIENT_SECRET, PROM_AWS_SECRET_ACCESS_KEY, PROM_TLS_CERT, PROM_TLS_KEY, PROM_TLS_CA]
newrelic:
  params:  [NEWRELIC_ACCOUNT_ID, NEWRELIC_REGION]
  secrets: [NEWRELIC_API_KEY]
opensearch:
  params:  [OPENSEARCH_URL, OPENSEARCH_USER, OPENSEARCH_LOG_INDEX, OPENSEARCH_VERIFY_CERTS]
  secrets: [OPENSEARCH_PASSWORD]
gitlab:
  params:  [GITLAB_BASE_URL, GITLAB_REPO_MAP]
  secrets: [GITLAB_TOKEN]
{{- end -}}

{{/* Names of the enabled MCP servers, comma-joined in catalog order ("" when none). Nil-safe:
     `helm upgrade --reuse-values` from a chart without `mcp` carries no `mcp` key at all. */}}
{{- define "velai.mcpEnabled" -}}
{{- $mcp := .Values.mcp | default dict -}}
{{- $on := list -}}
{{- range $name := list "kubernetes" "prometheus" "newrelic" "opensearch" "gitlab" -}}
{{- if (index $mcp $name | default dict).enabled -}}{{- $on = append $on $name -}}{{- end -}}
{{- end -}}
{{- join "," $on -}}
{{- end -}}

{{- define "velai.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end -}}

{{/* DATABASE_URL from the chart-managed secret (Postgres in-cluster or external). */}}
{{- define "velai.dbEnvFrom" -}}
{{- if or .Values.postgresql.enabled .Values.postgresql.externalUrl }}
- secretRef:
    name: {{ include "velai.fullname" . }}-db
    optional: true
{{- end }}
{{- end -}}

{{- define "velai.redisUrl" -}}
{{- if .Values.redis.enabled -}}
redis://{{ include "velai.fullname" . }}-redis:{{ .Values.redis.port }}
{{- end -}}
{{- end -}}

{{/* One key out of <fullname>-agent-keys (agent-keys.yaml). Call with (dict "root" $ "key" "<KEY>"). */}}
{{- define "velai.agentKeyEnv" -}}
- name: {{ .key }}
  valueFrom:
    secretKeyRef:
      name: {{ include "velai.fullname" .root }}-agent-keys
      key: {{ .key }}
{{- end -}}

{{/* MCP_AUTH_TOKEN for the agents that call the MCP servers (see internal-token.yaml). */}}
{{- define "velai.mcpTokenEnv" -}}
- name: MCP_AUTH_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .Values.internalToken.existingSecret | default (printf "%s-internal" (include "velai.fullname" .)) | quote }}
      key: MCP_AUTH_TOKEN
      optional: true
{{- end -}}

{{/* The agents' shared Redis (DB 1 — the orchestrator/console use DB 0). */}}
{{- define "velai.agentRedisUrl" -}}
redis://{{ include "velai.fullname" . }}-redis:{{ .Values.redis.port }}/1
{{- end -}}
