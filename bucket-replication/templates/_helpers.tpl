{{/*
Expand the name of the chart.
*/}}
{{- define "bucket-replication.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "bucket-replication.fullname" -}}
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
{{- define "bucket-replication.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "bucket-replication.labels" -}}
helm.sh/chart: {{ include "bucket-replication.chart" . }}
{{ include "bucket-replication.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "bucket-replication.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bucket-replication.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "bucket-replication.objectBucketClaims" -}}
{{ range $index, $bucket := (lookup "objectbucket.io/v1alpha1" "ObjectBucketClaim" $.Release.Namespace "").items }}
{{ printf "%s%s\n" "- " $bucket.metadata.name | nindent 6  }}
{{ end }}
{{- end }}
{{/*
Create the name of the service account to use
*/}}

{{- define "bucket-replication.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "bucket-replication.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of backup-secret
*/}}
{{- define "bucket-replication.secretName" -}}
{{ include "bucket-replication.fullname" . }}-aws-credentials
{{- end }}

{{- define  "bucket-replication.image" -}}
{{- $imageConfigMap := (lookup "v1" "ConfigMap" .Release.Namespace .Values.configuration.jenkinsAgentImageCMName) }}
{{- $configMapData  := get $imageConfigMap.data "jenkinsAgentImage" }}
{{- $configMapData -}}
{{- end -}}

{{- define "bucket-replication.secretData" -}}
{{- if and .Values.global.registryBackup.obc.bucketSecretAccessKey .Values.global.registryBackup.obc.bucketAccessKeyId }}
{{- $customAccessKey := .Values.global.registryBackup.obc.bucketSecretAccessKey | b64enc }}
{{- $customSecretAccessKey := .Values.global.registryBackup.obc.bucketAccessKeyId | b64enc }}
{{ printf "%s: %s\n" "AWS_ACCESS_KEY_ID" $customAccessKey }}
{{ printf "%s: %s\n" "AWS_SECRET_ACCESS_KEY" $customSecretAccessKey }}
{{- else}}
{{- $backupSecret := (lookup "v1" "Secret" .Values.configuration.defaultCredentialsSecretNamespace  .Values.configuration.defaultCredentialsSecretName) }}
{{- $secretData := (get $backupSecret "data") }}
{{- $accessKeyId := (get $secretData "backup-s3-like-storage-access-key-id") | quote | default dict }}
{{- $secretAccessKey := (get $secretData "backup-s3-like-storage-secret-access-key") | quote | default dict }}
{{ printf "%s: %s\n" "AWS_ACCESS_KEY_ID" $accessKeyId }}
{{ printf "%s: %s\n" "AWS_SECRET_ACCESS_KEY" $secretAccessKey }}
{{- end }}
{{- end }}

{{- define "bucket-replication.backupBucket" -}}
{{- if  .Values.global.registryBackup.obc.backupBucket }}
{{- .Values.global.registryBackup.obc.backupBucket }}
{{- else }}
{{- $backupSecret := (lookup "v1" "Secret" .Values.configuration.defaultCredentialsSecretNamespace  .Values.configuration.defaultCredentialsSecretName) }}
{{- $secretData := (get $backupSecret "data") }}
{{- $backupBucket := (get $secretData "backup-s3-like-storage-location") | default dict }}
{{ printf "%s" $backupBucket }}
{{- end }}
{{- end }}

{{- define "bucket-replication.minioEndpoint" -}}
{{- if .Values.global.registryBackup.obc.endpoint }}
{{- .Values.global.registryBackup.obc.endpoint }}
{{- else }}
{{- $backupSecret := (lookup "v1" "Secret" .Values.configuration.defaultCredentialsSecretNamespace  .Values.configuration.defaultCredentialsSecretName) }}
{{- $secretData := (get $backupSecret "data") }}
{{- $minioEndpoint := (get $secretData "backup-s3-like-storage-url") | default dict }}
{{ printf "%s" $minioEndpoint }}
{{- end }}
{{- end }}
