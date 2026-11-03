{{/*
Expand the name of the chart.
*/}}
{{- define "bucket-backup-restore.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "bucket-backup-restore.fullname" -}}
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
{{- define "bucket-backup-restore.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "bucket-backup-restore.labels" -}}
helm.sh/chart: {{ include "bucket-backup-restore.chart" . }}
{{ include "bucket-backup-restore.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "bucket-backup-restore.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bucket-backup-restore.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "bucket-backup-restore.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "bucket-backup-restore.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Container image
*/}}
{{- define "bucket-backup-restore.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}

{{/*
Name of the Secret holding credentials, empty if there is none
*/}}
{{- define "bucket-backup-restore.secretName" -}}
{{- if .Values.existingSecret }}
{{- .Values.existingSecret }}
{{- else if include "bucket-backup-restore.hasSecretValues" . }}
{{- include "bucket-backup-restore.fullname" . }}
{{- end }}
{{- end }}

{{- define "bucket-backup-restore.hasSecretValues" -}}
{{- range $key, $value := .Values.secrets }}
{{- if $value }}true{{ end }}
{{- end }}
{{- end }}

{{/*
Fail early on values from chart versions < 1.0.0. Called from validate.yaml.
Remove in 2.0.0.
*/}}
{{- define "bucket-backup-restore.validateValues" -}}
{{- if and .Values.app .Values.app.cronSchedule }}
{{- fail "app.cronSchedule was renamed to backup.schedule" }}
{{- end }}
{{- if .Values.jobAnnotations }}
{{- fail "jobAnnotations was renamed to podAnnotations" }}
{{- end }}
{{- if .Values.notificationSlack }}
{{- fail "notificationSlack was replaced by secrets.slack_webhook_url and deployNotification.enabled" }}
{{- end }}
{{- if or .Values.command .Values.args }}
{{- fail "command/args were replaced by backup.args / restore.args, e.g. [\"backup\"]" }}
{{- end }}
{{- end }}

{{/*
True if the jobs get an rclone.conf from the Secret
*/}}
{{- define "bucket-backup-restore.hasRcloneConfig" -}}
{{- if or .Values.existingSecret .Values.secrets.rclone }}true{{ end }}
{{- end }}

{{/*
Environment variables for a job. Each job only gets the credentials it needs:
backup jobs never see the decryption key.
Usage: include "bucket-backup-restore.env" (dict "root" $ "env" .Values.backup.env "component" "backup")
*/}}
{{- define "bucket-backup-restore.env" -}}
{{- $root := .root }}
{{- $secretName := include "bucket-backup-restore.secretName" $root }}
{{- $secretEnv := dict
  "AWS_ACCESS_KEY_ID" "aws_access_key_id"
  "AWS_SECRET_ACCESS_KEY" "aws_secret_access_key"
  "SLACK_WEBHOOK_URL" "slack_webhook_url" }}
{{- if eq .component "restore" }}
{{- $_ := set $secretEnv "AGE_IDENTITY" "age_identity" }}
{{- end }}
{{- /* With existingSecret, reference every key (optional: true skips missing ones);
       with the chart's own Secret, only the keys that have a value */}}
{{- range $name, $key := $secretEnv }}
{{- if or $root.Values.existingSecret (and $secretName (get $root.Values.secrets $key)) }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $key }}
      optional: true
{{- end }}
{{- end }}
{{- range $name, $value := merge (dict) (.env | default dict) $root.Values.env }}
- name: {{ $name }}
  value: {{ $value | toString | quote }}
{{- end }}
{{- with $root.Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Job template shared by the backup and restore CronJobs.
Usage: include "bucket-backup-restore.jobTemplate" (dict "root" $ "job" .Values.backup "component" "backup")
*/}}
{{- define "bucket-backup-restore.jobTemplate" -}}
{{- $root := .root }}
{{- $job := .job }}
metadata:
  labels:
    {{- include "bucket-backup-restore.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  backoffLimit: {{ $job.backoffLimit }}
  {{- with $job.activeDeadlineSeconds }}
  activeDeadlineSeconds: {{ . }}
  {{- end }}
  {{- with $job.ttlSecondsAfterFinished }}
  ttlSecondsAfterFinished: {{ . }}
  {{- end }}
  template:
    metadata:
      labels:
        {{- include "bucket-backup-restore.selectorLabels" $root | nindent 8 }}
        app.kubernetes.io/component: {{ .component }}
        {{- with $root.Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- with $root.Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      restartPolicy: Never
      # Service links would inject variables like <SERVICE>_PORT=tcp://... that may clash with configuration
      enableServiceLinks: false
      serviceAccountName: {{ include "bucket-backup-restore.serviceAccountName" $root }}
      automountServiceAccountToken: {{ $root.Values.serviceAccount.automountServiceAccountToken }}
      {{- with $root.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.priorityClassName }}
      priorityClassName: {{ . }}
      {{- end }}
      {{- with $root.Values.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ .component }}
          image: {{ include "bucket-backup-restore.image" $root | quote }}
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          args:
            {{- toYaml $job.args | nindent 12 }}
          env:
            - name: WORK_DIR
              value: /work
            {{- include "bucket-backup-restore.env" (dict "root" $root "env" $job.env "component" .component) | trim | nindent 12 }}
          {{- with $root.Values.envFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $root.Values.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $root.Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            - name: work
              mountPath: /work
            - name: tmp
              mountPath: /tmp
            {{- if include "bucket-backup-restore.hasRcloneConfig" $root }}
            - name: rclone-config
              mountPath: /config/rclone
              readOnly: true
            {{- end }}
            {{- with $root.Values.extraVolumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
      volumes:
        - name: work
          {{- if $root.Values.workDir.volume }}
          {{- toYaml $root.Values.workDir.volume | nindent 10 }}
          {{- else }}
          emptyDir:
            sizeLimit: {{ $root.Values.workDir.sizeLimit }}
          {{- end }}
        - name: tmp
          emptyDir:
            sizeLimit: 256Mi
        {{- if include "bucket-backup-restore.hasRcloneConfig" $root }}
        - name: rclone-config
          secret:
            secretName: {{ include "bucket-backup-restore.secretName" $root }}
            # an existing Secret may have no rclone key when all remotes come from RCLONE_CONFIG_* variables
            optional: {{ not $root.Values.secrets.rclone }}
            items:
              - key: rclone
                path: rclone.conf
        {{- end }}
        {{- with $root.Values.extraVolumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- with $root.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
