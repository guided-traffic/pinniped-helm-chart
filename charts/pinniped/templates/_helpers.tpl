{{/*
Namespace for the supervisor component.
*/}}
{{- define "pinniped.supervisor.namespace" -}}
{{- .Values.supervisor.namespaceOverride | default .Values.namespace | default .Release.Namespace -}}
{{- end }}

{{/*
Namespace for the concierge component.
*/}}
{{- define "pinniped.concierge.namespace" -}}
{{- .Values.concierge.namespaceOverride | default .Values.namespace | default .Release.Namespace -}}
{{- end }}

{{/*
Full image reference (repository:tag[@digest]).
*/}}
{{- define "pinniped.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if .Values.image.digest -}}
{{- printf "%s:%s@%s" .Values.image.repository $tag .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end }}

{{/*
Standard chart labels appended to the upstream `app` label.
*/}}
{{- define "pinniped.chartLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "pinniped.supervisor.labels" -}}
app: pinniped-supervisor
{{ include "pinniped.chartLabels" . }}
{{- end }}

{{- define "pinniped.concierge.labels" -}}
app: pinniped-concierge
{{ include "pinniped.chartLabels" . }}
{{- end }}
