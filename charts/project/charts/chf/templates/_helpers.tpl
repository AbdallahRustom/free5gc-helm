#
# Software Name : helm
#
{{/*
Expand the name of the chart.
*/}}
{{- define "chf.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "chf.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "chf.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "chf.labels" -}}
helm.sh/chart: {{ include "chf.chart" . }}
{{ include "chf.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "chf.selectorLabels" -}}
app.kubernetes.io/name: {{ include "chf.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
CHF Pod Annotations
*/}}
{{- define "chf.chfAnnotations" -}}
{{- with .Values.chf }}
{{- if .podAnnotations }}
{{- toYaml .podAnnotations }}
{{- end }}
{{- end }}
{{- end }}

{{/* CDR resource names */}}
{{- define "chf.cdr.pvcName" -}}
{{- default (printf "%s-cdr-pvc" (include "chf.fullname" .)) .Values.cdr.pvc.name -}}
{{- end }}

{{- define "chf.cdr.secretName" -}}
{{- printf "%s-sftp" (include "chf.fullname" .) -}}
{{- end }}

{{- define "chf.cdr.uploaderConfigMapName" -}}
{{- printf "%s-cdr-uploader" (include "chf.fullname" .) -}}
{{- end }}
