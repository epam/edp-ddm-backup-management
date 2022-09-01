{{- define "backup-script" }}
#!/usr/bin/env bash
backup_secret_name="backup-credentials"
backup_ttl="120h"
edp_project="control-plane"
declare -a openshift_resources=("service" "gerrit" "jenkins" "codebase")

execution_time=$(date '+%Y-%m-%d-%H-%M-%S')
backup_name="${edp_project}-${execution_time}"
minio_endpoint=$(oc get secret $backup_secret_name -n $edp_project  -o jsonpath='{.data.backup-s3-like-storage-url}' | base64 -d)
minio_backup_bucket_name=$(oc get secret $backup_secret_name -n $edp_project  -o jsonpath='{.data.backup-s3-like-storage-location}' | base64 -d)
minio_username=$(oc get secret ${backup_secret_name} -n ${edp_project}  -o jsonpath='{.data.backup-s3-like-storage-access-key-id}' | base64 -d)
minio_password=$(oc get secret ${backup_secret_name} -n ${edp_project}  -o jsonpath='{.data.backup-s3-like-storage-secret-access-key}' | base64 -d)

mkdir -p ~/.config/rclone

echo "
[minio]
type = s3
env_auth = false
access_key_id = ${minio_username}
secret_access_key = ${minio_password}
endpoint = ${minio_endpoint}
region = eu-central-1
location_constraint = EU
acl = bucket-owner-full-control" > ~/.config/rclone/rclone.conf


echo "Backup $edp_project namespace with velero"
velero backup create ${backup_name} --include-namespaces ${edp_project} --ttl ${backup_ttl} --wait

echo "Backup Openshift resources_kind to Minio"
mkdir -p /tmp/openshift-resources
for resources_kind in "${openshift_resources[@]}"
do
    for name in $(oc get ${resources_kind} -n ${edp_project} --no-headers -o custom-columns="NAME:.metadata.name" | sed 'N;s/\n/ /g')
    do
      echo ${resources_kind}/${name}
      oc get ${resources_kind}/${name} -n ${edp_project} -o yaml > /tmp/openshift-resources/${resources_kind}-${name}.yaml
    done
done

rclone copy /tmp/openshift-resources minio:/${minio_backup_bucket_name}/backups/${backup_name}/openshift-resources
rm -rf /tmp/openshift-resources
{{- end }}
