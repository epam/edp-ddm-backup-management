{{- define "restore-job-template"  }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Values.restoreJob.name }}-REPLACE-IT
spec:
 template:
  spec:
    containers:
    - name: {{ .Values.restoreJob.name }}
      image: {{ include "velero.job.image" . }}
      imagePullPolicy: IfNotPresent
      env:
      - name: BACKUP_NAME
        value: REPLACE-IT
      command:
        - /bin/sh
        - -c
        - /tmp/backup/{{ .Values.restoreJob.restoreScriptName }}
      volumeMounts:
        - mountPath: /tmp/backup/{{ .Values.restoreJob.restoreScriptName }}
          subPath: {{ .Values.restoreJob.restoreScriptName }}
          name: backup
    volumes:
    - name: backup
      configMap:
        name: {{ .Values.restoreJob.configMapName }}
        defaultMode: 0777
    restartPolicy: OnFailure
    serviceAccountName: {{ .Values.cronJob.name }}
    serviceAccount: {{ .Values.cronJob.name }}
{{- end }}