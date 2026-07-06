{{/*
Expand the name of the chart.
*/}}
{{- define "parabol.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "parabol.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "parabol.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "parabol.labels" -}}
helm.sh/chart: {{ include "parabol.chart" . }}
{{ include "parabol.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "parabol.selectorLabels" -}}
app.kubernetes.io/name: {{ include "parabol.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "parabol.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "parabol.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Postgres resource name - single source of truth so DNS references and
the StatefulSet/Service metadata.name can never drift apart.
*/}}
{{- define "parabol.postgres.fullname" -}}
{{- printf "%s-postgres" (include "parabol.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Valkey resource name - same idea as postgres above.
*/}}
{{- define "parabol.valkey.fullname" -}}
{{- printf "%s-valkey" (include "parabol.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
AI embedder inference (text-embeddings-inference) resource name.
*/}}
{{- define "parabol.embedderInference.fullname" -}}
{{- printf "%s-embedder-inference" (include "parabol.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Embedder worker resource name.
*/}}
{{- define "parabol.embedder.fullname" -}}
{{- printf "%s-embedder" (include "parabol.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified Parabol app image reference.
*/}}
{{- define "parabol.image" -}}
{{- $repository := .Values.image.repository }}
{{- if .Values.image.registry }}
{{- printf "%s/%s:%s" .Values.image.registry $repository .Values.image.tag }}
{{- else }}
{{- printf "%s:%s" $repository .Values.image.tag }}
{{- end }}
{{- end }}

{{/*
Embedder worker image - defaults to the main Parabol app image unless
overridden independently.
*/}}
{{- define "parabol.embedder.image" -}}
{{- if .Values.embedder.image.repository }}
{{- $repository := .Values.embedder.image.repository }}
{{- if .Values.embedder.image.registry }}
{{- printf "%s/%s:%s" .Values.embedder.image.registry $repository .Values.embedder.image.tag }}
{{- else }}
{{- printf "%s:%s" $repository .Values.embedder.image.tag }}
{{- end }}
{{- else }}
{{- include "parabol.image" . }}
{{- end }}
{{- end }}

{{/*
Init container that blocks until Postgres is accepting connections.
Shared by the web Deployment and the embedder Deployment.
*/}}
{{- define "parabol.waitForPostgresInitContainer" -}}
- name: wait-for-postgres
  image: "{{ .Values.postgres.image.repository }}:{{ .Values.postgres.image.tag }}"
  command:
    - sh
    - -c
    - |
      until pg_isready -h {{ include "parabol.postgres.fullname" . }} -p {{ .Values.postgres.service.port }} -U "$POSTGRES_USER"; do
        echo "waiting for postgres...";
        sleep 5;
      done
  envFrom:
    - secretRef:
        name: {{ include "parabol.postgres.secretName" . }}
{{- end }}

{{/*
Init container that runs the preDeploy bundle (node dist/preDeploy.js):
Kysely migrations, storing persisted GraphQL queries (queryMap.json) into
the QueryMap table, priming integration providers from env, and pushing
CDN assets (a no-op when FILE_STORE_PROVIDER=local, the default here).
Storing persisted queries specifically is not optional - the production
client only sends query hashes, and the server 404s (PersistedQueryNotFound)
on every operation until QueryMap is populated. Idempotent - safe to run
on every pod start. Only wired into the web Deployment, which this chart
hard-caps at replicaCount 1, so this runs exactly once per rollout rather
than racing across workloads.
*/}}
{{- define "parabol.predeployInitContainer" -}}
- name: predeploy
  image: {{ include "parabol.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  args: ["node", "dist/preDeploy.js"]
  securityContext:
    {{- toYaml .Values.parabol.securityContext | nindent 4 }}
  {{- include "parabol.envFrom" . | nindent 2 }}
  {{- include "parabol.computedEnv" . | nindent 2 }}
    - name: SERVER_ID
      value: {{ .Values.parabol.serverId | quote }}
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
{{- end }}

{{/*
Shared envFrom block: the ConfigMap + Secret pair holding the bulk of the
app's ~30 env vars. Used identically by the web Deployment and the
embedder Deployment so those vars are defined exactly once.
*/}}
{{- define "parabol.envFrom" -}}
envFrom:
  - configMapRef:
      name: {{ include "parabol.fullname" . }}
  - secretRef:
      name: {{ include "parabol.fullname" . }}
{{- end }}

{{/*
Computed env vars that can't live in the static ConfigMap because they're
derived from chart-managed resource names (Postgres/Valkey Service DNS).
Shared by the web Deployment, embedder Deployment, and migration Job.
*/}}
{{- define "parabol.computedEnv" -}}
env:
  - name: POSTGRES_HOST
    value: {{ include "parabol.postgres.fullname" . }}
  - name: REDIS_URL
    value: "redis://{{ include "parabol.valkey.fullname" . }}:{{ .Values.valkey.service.port }}"
{{- end }}

{{/*
Name of the Secret holding Postgres credentials (POSTGRES_USER/PASSWORD/DB) -
either the user-supplied existingSecret or the one this chart manages.
*/}}
{{- define "parabol.postgres.secretName" -}}
{{- if .Values.postgres.auth.existingSecret }}
{{- .Values.postgres.auth.existingSecret }}
{{- else }}
{{- include "parabol.postgres.fullname" . }}
{{- end }}
{{- end }}

{{/*
Resolve the Postgres password: prefer an explicit value, then an existing
Secret in the release namespace (so `helm upgrade` doesn't rotate it out
from under an already-initialized data directory), else generate one.
*/}}
{{- define "parabol.postgres.password" -}}
{{- if .Values.postgres.auth.existingSecret }}
{{- $secret := lookup "v1" "Secret" .Release.Namespace .Values.postgres.auth.existingSecret }}
{{- if $secret }}
{{- index $secret.data "POSTGRES_PASSWORD" | b64dec }}
{{- end }}
{{- else if .Values.postgres.auth.password }}
{{- .Values.postgres.auth.password }}
{{- else }}
{{- $secret := lookup "v1" "Secret" .Release.Namespace (include "parabol.postgres.fullname" .) }}
{{- if $secret }}
{{- index $secret.data "POSTGRES_PASSWORD" | b64dec }}
{{- else }}
{{- randAlphaNum 32 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Resolve SERVER_SECRET the same way: prefer explicit value, then reuse an
existing Secret's value, else generate one.
*/}}
{{- define "parabol.serverSecret" -}}
{{- if .Values.parabol.secrets.serverSecret }}
{{- .Values.parabol.secrets.serverSecret }}
{{- else }}
{{- $secret := lookup "v1" "Secret" .Release.Namespace (include "parabol.fullname" .) }}
{{- if $secret }}
{{- index $secret.data "SERVER_SECRET" | b64dec }}
{{- else }}
{{- randAlphaNum 32 }}
{{- end }}
{{- end }}
{{- end }}
