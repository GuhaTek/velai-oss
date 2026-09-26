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
