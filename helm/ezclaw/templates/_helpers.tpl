{{- define "ezclaw.fullname" -}}
ezclaw-{{ .Values.bot.name }}
{{- end -}}

{{- define "ezclaw.labels" -}}
app.kubernetes.io/name: ezclaw
app.kubernetes.io/instance: {{ .Values.bot.name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
{{- end -}}
