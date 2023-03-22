{{- define "restore-script" }}
#!/usr/bin/env bash

if [[ -z "$BACKUP_NAME" ]] || [[ "$BACKUP_NAME" == "REPLACE_IT" ]]; then
    echo 'Environment variable with backup_name is missing or value has not change.
Please add/change $BACKUP_NAME to pod parameters'
    exit 1
fi

backup_name="$BACKUP_NAME"
backup_secret_name="backup-credentials"
backup_ttl="120h"
edp_project="control-plane"
resource_type="customresourcedefinition"
resource_name="gerritmergerequests.v2.edp.epam.com"


echo "Restoring persistent resources from backup from Velero"
velero restore  create --from-backup ${backup_name} --include-resources secrets,configmaps,persistentvolumes,persistentvolumeclaims,roles,rolebindings,clusterrolebindings,clusterroles,podsecuritypolicies --wait
echo "Restoring resources from minio"
minio_endpoint=$(oc get secret $backup_secret_name -n $edp_project  -o jsonpath='{.data.backup-s3-like-storage-url}' | base64 -d)
minio_backup_bucket_name=$(oc get secret $backup_secret_name -n $edp_project  -o jsonpath='{.data.backup-s3-like-storage-location}' | base64 -d)
minio_access_key=$(oc get secret ${backup_secret_name} -n ${edp_project}  -o jsonpath='{.data.backup-s3-like-storage-access-key-id}' | base64 -d)
minio_secret_key=$(oc get secret ${backup_secret_name} -n ${edp_project}  -o jsonpath='{.data.backup-s3-like-storage-secret-access-key}' | base64 -d)

mkdir -p ~/.config/rclone

echo "
[minio]
type = s3
env_auth = false
access_key_id = ${minio_access_key}
secret_access_key = ${minio_secret_key}
endpoint = ${minio_endpoint}
region = eu-central-1
location_constraint = EU
acl = bucket-owner-full-control" > ~/.config/rclone/rclone.conf


mkdir -p /tmp/openshift_resources
rclone copy minio:/${minio_backup_bucket_name}/openshift-backups/backups/${backup_name}/openshift-resources /tmp/openshift_resources
oc patch ${resource_type} ${resource_name} --type='json' -p='[{"op":"replace","path":"/spec/versions/0/subresources","value":null}]'
for op_object in $(ls /tmp/openshift_resources); do oc apply -f /tmp/openshift_resources/${op_object};done
oc patch ${resource_type} ${resource_name} --type='json' -p='[{"op":"add","path":"/spec/versions/0/subresources","value":{"status":{}}}]'
rm -rf /tmp/openshift_resources

echo "Restore Jenkins"
velero create restore --from-backup ${backup_name} -l app=jenkins --wait
echo "Restore Gerrit"
velero create restore --from-backup ${backup_name} -l app=gerrit --wait
echo "Chill before next step"
sleep 120
echo "Restore Jenkins Operator"
velero create restore --from-backup ${backup_name} -l app.kubernetes.io/name=jenkins-operator --wait
echo "Restore Gerrit Operator"
velero create restore --from-backup ${backup_name} -l app.kubernetes.io/name=gerrit-operator --wait
echo "Chill before next step"
sleep 120
echo "Restore all resources that left"
velero create restore --from-backup ${backup_name} --exclude-resources secrets,configmaps,persistentvolumes,persistentvolumeclaims,roles,rolebindings,clusterrolebindings,clusterroles,podsecuritypolicies --wait
{{- end }}