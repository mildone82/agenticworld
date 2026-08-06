{{- define "multica.name" -}}multica{{- end -}}
{{- define "multica.fullname" -}}{{ .Release.Name }}{{- end -}}
{{- define "multica.labels" -}}
app.kubernetes.io/name: {{ include "multica.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}
{{- define "multica.selectorLabels" -}}
app.kubernetes.io/name: {{ include "multica.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}
{{- define "multica.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "multica.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- required "serviceAccount.name is required when serviceAccount.create=false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
{{- define "multica.backendImage" -}}
{{- if .Values.images.backend.digest -}}
{{ printf "%s@%s" .Values.images.backend.repository .Values.images.backend.digest }}
{{- else -}}
{{ printf "%s:%s" .Values.images.backend.repository .Values.images.backend.tag }}
{{- end -}}
{{- end -}}
{{- define "multica.frontendImage" -}}
{{- if .Values.images.frontend.digest -}}
{{ printf "%s@%s" .Values.images.frontend.repository .Values.images.frontend.digest }}
{{- else -}}
{{ printf "%s:%s" .Values.images.frontend.repository .Values.images.frontend.tag }}
{{- end -}}
{{- end -}}
