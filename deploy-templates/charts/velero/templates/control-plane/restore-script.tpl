{{- define "restore-script" }}
#!/usr/bin/env bash
set -e

if [[ -z "${BACKUP_NAME}" ]] || [[ "${BACKUP_NAME}" = "REPLACE_IT" ]]; then
    echo "Environment variable with backup_name is missing or value has not change.
Please add/change ${BACKUP_NAME} to pod parameters"
    exit 1
fi

backup_name="${BACKUP_NAME}"
minio_endpoint_secret_name="backup-credentials"
edp_project="control-plane"
resource_type="customresourcedefinition"
resources_folder="/tmp/openshift_resources"

declare -a crds_to_patch=("gerritmergerequests.v2.edp.epam.com" "codebases.v2.edp.epam.com" "jenkins.v2.edp.epam.com" "gerrits.v2.edp.epam.com")

function get_backup_bucket() {
  local namespace backup_storage_location_name backup_bucket_name;
  namespace="velero";
  backup_storage_location_name=$(oc get backups -n "${namespace}" "${backup_name}" -o jsonpath='{.spec.storageLocation}')
  backup_bucket_name=$(oc get BackupStorageLocation -n "${namespace}" "${backup_storage_location_name}" -o jsonpath='{.spec.objectStorage.bucket}')
  echo "${backup_bucket_name}"
}

delete_namespace(){
    declare -a groups=( "v2.edp.epam.com" "v1.edp.epam.com" )
    if [ ! "$(oc get namespace ${edp_project} --ignore-not-found | wc -c)" -eq 0 ]; then
        if [ ! "$(oc get deployment -n ${edp_project} --ignore-not-found | wc -c)" -eq 0 ];then
          oc -n "${edp_project}" scale deployments --all=true --replicas 0
        else
          echo "[DEBUG] Deployments already deleted from namespace ${edp_project}"
        fi
        for group in "${groups[@]}";do
            for kind in $(oc get crd -o json | jq -r '.items[] | select(.spec.group == "'${group}'") | .spec.names.plural');do
                if [ ! "$(oc -n "${edp_project}" get "${kind}" --ignore-not-found | wc -c)" -eq 0 ];then
                    oc -n "${edp_project}" get "${kind}" --no-headers -o=custom-columns='NAME:.metadata.name' | xargs oc -n "${edp_project}" patch "${kind}" -p '{"metadata":{"finalizers":null}}' --type=merge
                else
                  echo "[DEBUG] CRs with kind ${kind} are already deleted, or not found."
                fi
            done
        done
        oc delete namespace ${edp_project} --wait=true
    else
      echo "Project ${edp_project} already deleted"
    fi
}

minio_resources(){
    declare -a resources_kind=("service" "route" "endpointslice")
    resource_name="platform-minio"
    for kind in "${resources_kind[@]}";do
      if [ "${1}" == "delete" ];then
              oc delete "${kind}" "${resource_name}" --ignore-not-found
      else
          if [ ! "$(oc get "${kind}" "${resource_name}" --ignore-not-found=true | wc -c)" -eq 0 ];then
              echo "[INFO] Resource ${kind} ${resource_name} already exist. Continuing restore."
          else
              if [ ! "$(oc -n "${edp_project}" get "${kind}" "${resource_name}" --ignore-not-found=true | wc -c)" -eq 0 ];then
                  oc get -n "${edp_project}" "${kind}" "${resource_name}" -o json | jq 'del(.metadata.namespace,.spec.clusterIPs,.spec.clusterIP,.metadata.resourceVersion,.metadata.uid,.metadata.managedFields,.metadata.selfLink,.metadata.ownerReferences)' | oc create -f -
              else
                  echo "Exit from script, resource ${kind} ${resource_name} not found in ${edp_project}"
                  exit 1
              fi
          fi
      fi
   done
}


minio_resources "create"

oc delete -n ${edp_project} ValidatingWebhookConfiguration "edp-codebase-operator-validating-webhook-configuration-${edp_project}" --ignore-not-found

delete_namespace

echo "Initing restore"
velero restore create --from-backup "${backup_name}" --include-resources secrets,configmaps --wait

echo "Restoring resources from minio"
minio_endpoint=$(oc get secret $minio_endpoint_secret_name -n $edp_project  -o jsonpath='{.data.backup-s3-like-storage-url}' | base64 -d)
minio_backup_bucket_name=$(get_backup_bucket)

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

mkdir -p "${resources_folder}"

rclone copy "minio:/${minio_backup_bucket_name}/openshift-backups/backups/${backup_name}/openshift-resources" ${resources_folder}

for resource_name in "${crds_to_patch[@]}";do
    oc patch "${resource_type}" "${resource_name}" --type='json' -p='[{"op":"replace","path":"/spec/versions/0/subresources","value":null}]'
done

for op_object in "${resources_folder}"/*; do
  [[ -e "${op_object}" ]] || break
  oc apply -f "${op_object}";
done

for resource_name in "${crds_to_patch[@]}";do
    oc patch "${resource_type}" "${resource_name}" --type='json' -p='[{"op":"add","path":"/spec/versions/0/subresources","value":{"status":{}}}]'
done

oc adm policy add-scc-to-user anyuid -z jenkins -n "${edp_project}"
oc adm policy add-scc-to-user anyuid -z istio-ingressgateway-control-plane-main-service-account -n "${edp_project}"

velero create restore --from-backup "${backup_name}" --wait

sleep 120 && oc delete pod -n "${edp_project}" --all && sleep 120

minio_resources "delete"
{{- end }}
