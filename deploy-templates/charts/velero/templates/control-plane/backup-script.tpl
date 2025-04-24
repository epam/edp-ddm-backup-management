{{- define "backup-script" }}
#!/usr/bin/env bash
minio_endpoint_secret_name="backup-credentials"
backup_ttl=$(({{ .Values.backup.controlPlane.expires_in_days | default 5 }}*24))
edp_project="control-plane"
declare -a openshift_resources=("service" "gerrit" "jenkins" "codebase" "gerritmergerequest" "validatingwebhookconfiguration")
codebase_webhook_name="edp-codebase-operator-validating-webhook-configuration-control-plane"

execution_time=$(date '+%Y-%m-%d-%H-%M-%S')
backup_name="${edp_project}-${execution_time}"
minio_endpoint=$(oc get secret $minio_endpoint_secret_name -n $edp_project  -o jsonpath='{.data.backup-s3-like-storage-url}' | base64 -d)
minio_backup_bucket_name={{ .Values.configuration.centralComponentBackupBucket }}
storage_location={{ .Values.configuration.centralComponentBackupBucket }}

mkdir -p ~/.config/rclone

echo "
[minio]
type = s3
provider = Other
env_auth = true
endpoint = ${minio_endpoint}
region = eu-central-1
location_constraint = EU
server_side_encryption = aws:kms
acl = bucket-owner-full-control" > ~/.config/rclone/rclone.conf


echo "Backup $edp_project namespace with velero"
velero backup create ${backup_name} --storage-location ${storage_location} --include-namespaces ${edp_project} --ttl ${backup_ttl}h --wait

echo "Backup Openshift resource_kind to Minio"
mkdir -p /tmp/openshift-resources
for resource_kind in "${openshift_resources[@]}"
do
    if [[ "${resource_kind}" == "service" ]];then
        oc get ${resource_kind}/gerrit -n ${edp_project} -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.selfLink,.metadata.managedFields,.metadata.creationTimestamp,.metadata.annotations,.metadata.generation,.metadata.ownerReferences,.spec.clusterIP,.spec.clusterIPs)' > /tmp/openshift-resources/${resource_kind}-gerrit.json
    elif [[ "${resource_kind}" == "validatingwebhookconfiguration" ]];then
        oc get ${resource_kind} "${codebase_webhook_name}" -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.selfLink,.metadata.managedFields,.metadata.creationTimestamp,.metadata.annotations,.metadata.generation,.metadata.ownerReferences)' > /tmp/openshift-resources/${resource_kind}.json
    else
      for name in $(oc get ${resource_kind} -n ${edp_project} --no-headers -o custom-columns="NAME:.metadata.name" | sed 'N;s/\n/ /g')
      do
        echo ${resource_kind}/${name}
        if [[ $resource_kind =~ "gerritmergerequest" ]]; then
          oc get ${resource_kind}/${name} -n ${edp_project} -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.selfLink,.metadata.managedFields,.metadata.creationTimestamp,.metadata.annotations,.metadata.generation,.metadata.ownerReferences)' > /tmp/openshift-resources/${resource_kind}-${name}.json
        else
          oc get ${resource_kind}/${name} -n ${edp_project} -o yaml > /tmp/openshift-resources/${resource_kind}-${name}.yaml
        fi
      done
    fi

done

rclone copy /tmp/openshift-resources minio:/${minio_backup_bucket_name}/openshift-backups/backups/${backup_name}/openshift-resources
rm -rf /tmp/openshift-resources
{{- end }}
