{{- define "git-proxy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "git-proxy.fullname" -}}
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

{{- define "git-proxy.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "git-proxy.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "git-proxy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "git-proxy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "git-proxy.serviceAccountName" -}}
{{- if or .Values.serviceAccount.create (eq .Values.upstream.auth "entraWorkloadIdentity") }}
{{- default (include "git-proxy.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Secret holding the credential the chart creates (PAT or client secret). */}}
{{- define "git-proxy.credentialsSecret" -}}
{{- printf "%s-credentials" (include "git-proxy.fullname" .) }}
{{- end }}

{{/* Fails early with a readable message instead of a crash-looping pod. */}}
{{- define "git-proxy.validate" -}}
{{- if not .Values.repos }}
{{- fail "repos: set at least one Azure DevOps repository URL, e.g. https://dev.azure.com/<org>/<project>/_git/<repo>" }}
{{- end }}
{{- $u := .Values.upstream }}
{{- if eq $u.auth "pat" }}
{{- if not (or $u.pat.value $u.pat.existingSecret) }}
{{- fail "upstream.auth=pat: set upstream.pat.value or upstream.pat.existingSecret" }}
{{- end }}
{{- else if or (eq $u.auth "entraWorkloadIdentity") (eq $u.auth "entraClientSecret") }}
{{- if not (and $u.entra.clientId $u.entra.tenantId) }}
{{- fail (printf "upstream.auth=%s: set upstream.entra.clientId and upstream.entra.tenantId" $u.auth) }}
{{- end }}
{{- if and (eq $u.auth "entraClientSecret") (not (or $u.entra.clientSecret.value $u.entra.clientSecret.existingSecret)) }}
{{- fail "upstream.auth=entraClientSecret: set upstream.entra.clientSecret.value or upstream.entra.clientSecret.existingSecret" }}
{{- end }}
{{- else }}
{{- fail (printf "upstream.auth must be pat, entraWorkloadIdentity or entraClientSecret, not %q" $u.auth) }}
{{- end }}
{{- if not (has .Values.proxyAuth (list "basic" "none")) }}
{{- fail "proxyAuth must be basic or none" }}
{{- end }}
{{- end }}
