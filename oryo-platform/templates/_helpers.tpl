{{/*
Expand the name of the chart.
*/}}
{{- define "oryo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully-qualified app name (release-name + chart-name, capped at 63 chars).
*/}}
{{- define "oryo.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Per-component fullname: <release-fullname>-<component>
*/}}
{{- define "oryo.componentName" -}}
{{- $ctx := index . 0 -}}
{{- $component := index . 1 -}}
{{- printf "%s-%s" (include "oryo.fullname" $ctx) $component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Chart label (chart + version).
*/}}
{{- define "oryo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every resource.
*/}}
{{- define "oryo.labels" -}}
helm.sh/chart: {{ include "oryo.chart" . }}
{{ include "oryo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: oryo-platform
{{- end -}}

{{/*
Selector labels (release-scoped).
*/}}
{{- define "oryo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "oryo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Per-component labels. Pass [ctx, "<component>"].
*/}}
{{- define "oryo.componentLabels" -}}
{{- $ctx := index . 0 -}}
{{- $component := index . 1 -}}
{{ include "oryo.labels" $ctx }}
app.kubernetes.io/component: {{ $component | quote }}
{{- end -}}

{{/*
Per-component selector labels. Pass [ctx, "<component>"].
*/}}
{{- define "oryo.componentSelectorLabels" -}}
{{- $ctx := index . 0 -}}
{{- $component := index . 1 -}}
{{ include "oryo.selectorLabels" $ctx }}
app.kubernetes.io/component: {{ $component | quote }}
{{- end -}}

{{/*
Pod template labels. Selector labels (required for Deployment/Job pod matching)
plus user-supplied global.podLabels and per-service svc.podLabels — merged in
that order so service-scoped labels win on conflicts.

Used for cloud workload-identity bindings that require a pod label, e.g. AKS:
  global:
    podLabels:
      azure.workload.identity/use: "true"

Pass [ctx, "<component>", svc] (svc may be nil for the db-init Job).
*/}}
{{- define "oryo.podLabels" -}}
{{- $ctx := index . 0 -}}
{{- $component := index . 1 -}}
{{- $svc := index . 2 -}}
{{- $globalPodLabels := default (dict) $ctx.Values.global.podLabels -}}
{{- $svcPodLabels := dict -}}
{{- if and $svc $svc.podLabels -}}
{{- $svcPodLabels = $svc.podLabels -}}
{{- end -}}
{{- $merged := merge (dict) $svcPodLabels $globalPodLabels -}}
{{ include "oryo.componentSelectorLabels" (list $ctx $component) }}
{{- range $k, $v := $merged }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end -}}

{{/*
ServiceAccount name to use.
*/}}
{{- define "oryo.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "oryo.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Resolve a fully-qualified image reference for a service.
Inputs:
  ctx     -- root context
  service -- service config (.Values.dashboard / .gateway / .workers)
*/}}
{{- define "oryo.image" -}}
{{- $ctx := index . 0 -}}
{{- $svc := index . 1 -}}
{{- $registry := $ctx.Values.global.imageRegistry -}}
{{- $tag := default $ctx.Values.global.imageTag $svc.image.tag -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry $svc.image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" $svc.image.repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
Common environment variables — emitted on every workload.
Drops empty values so they don't shadow defaults set elsewhere.
*/}}
{{- define "oryo.commonEnv" -}}
{{- $g := .Values.global -}}
{{- range $k, $v := $g.env }}
{{- if ne (toString $v) "" }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}
- name: DB_HOST
  value: {{ $g.db.host | quote }}
- name: DB_PORT
  value: {{ $g.db.port | quote }}
- name: DB_DATABASE
  value: {{ $g.db.database | quote }}
- name: DB_SSLMODE
  value: {{ $g.db.sslmode | quote }}
{{- end -}}

{{/*
Per-service environment block. Inputs: [ctx, service, componentName].
Renders:
  - common env (ENV_NAME, DOMAIN, DB_HOST, ...)
  - service-specific env map (svc.env)
  - DB_USER + DB_ROLE
  - APP_NAME + PORT (when svc.containerPort is set)
  - DB_PASSWORD from svc.db.passwordSecret (if set)
  - global.externalSecrets (env-from-secret refs)
  - svc.externalSecrets (per-service env-from-secret refs)
  - global.secrets via the chart-managed Secret
*/}}
{{- define "oryo.serviceEnv" -}}
{{- $ctx := index . 0 -}}
{{- $svc := index . 1 -}}
{{- $component := index . 2 -}}
{{ include "oryo.commonEnv" $ctx }}
{{- range $k, $v := $svc.env }}
{{- if ne (toString $v) "" }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}
{{- if $svc.db }}
{{- if $svc.db.user }}
- name: DB_USER
  value: {{ $svc.db.user | quote }}
{{- end }}
{{- if $svc.db.role }}
- name: DB_ROLE
  value: {{ $svc.db.role | quote }}
{{- end }}
{{- end }}
- name: APP_NAME
  value: {{ $component | quote }}
{{- if $svc.containerPort }}
- name: PORT
  value: {{ $svc.containerPort | quote }}
{{- end }}
{{- if and $svc.db $svc.db.passwordSecret $svc.db.passwordSecret.name }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $svc.db.passwordSecret.name | quote }}
      key: {{ default "password" $svc.db.passwordSecret.key | quote }}
{{- end }}
{{- range $envName, $ref := $ctx.Values.global.externalSecrets }}
- name: {{ $envName }}
  valueFrom:
    secretKeyRef:
      name: {{ $ref.secretName | quote }}
      key: {{ default "value" $ref.key | quote }}
{{- end }}
{{- range $envName, $ref := $svc.externalSecrets }}
- name: {{ $envName }}
  valueFrom:
    secretKeyRef:
      name: {{ $ref.secretName | quote }}
      key: {{ default "value" $ref.key | quote }}
{{- end }}
{{- if $ctx.Values.global.secrets }}
{{- range $k, $v := $ctx.Values.global.secrets }}
- name: {{ $k }}
  valueFrom:
    secretKeyRef:
      name: {{ include "oryo.fullname" $ctx }}-secrets
      key: {{ $k | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Affinity that requires nodes matching global.nodeArchitecture.

Defaults to *required* so EKS Auto Mode (which optimizes for cost/availability)
cannot silently provision a node of the wrong architecture. Set
`global.nodeArchitectureStrict: false` to fall back to *preferred*.
*/}}
{{- define "oryo.archAffinity" -}}
{{- if .Values.global.nodeArchitecture }}
nodeAffinity:
  {{- if ne (toString .Values.global.nodeArchitectureStrict) "false" }}
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - key: kubernetes.io/arch
            operator: In
            values:
              - {{ .Values.global.nodeArchitecture | quote }}
  {{- else }}
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      preference:
        matchExpressions:
          - key: kubernetes.io/arch
            operator: In
            values:
              - {{ .Values.global.nodeArchitecture | quote }}
  {{- end }}
{{- end }}
{{- end -}}
