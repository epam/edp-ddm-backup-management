{{- define "restore-script" }}
#!/usr/bin/env bash
set -e

if [[ -z "${BACKUP_NAME}" ]] || [[ "${BACKUP_NAME}" = "REPLACE_IT" ]]; then
    echo "Environment variable with backup_name is missing or value has not change.
Please add/change ${BACKUP_NAME} to pod parameters"
    exit 1
fi

backup_name="${BACKUP_NAME}"
backup_secret_name="backup-credentials"
edp_project="control-plane"
resource_type="customresourcedefinition"
resources_folder="/tmp/openshift_resources"

declare -a crds_to_patch=("gerritmergerequests.v2.edp.epam.com" "codebases.v2.edp.epam.com" "jenkins.v2.edp.epam.com" "gerrits.v2.edp.epam.com")
declare -a animals=("deployment,app=gerrit,gerrit" "deployment,app=jenkins,jenkins")

execution_time=$(date '+%Y-%m-%d-%H-%M-%S')
cloud_provider=$(oc get infrastructure cluster --no-headers -o jsonpath='{.status.platform}')


restic_wait() {
  while [[ $(oc get pods "${1}" -o 'jsonpath={..status.conditions[?(@.type=="Initialized")].status}' -n "${2}") != "True" ]]; do
    sleep 10
    echo "Restic is not initialized in pod ${1}"
  done
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

codebase_webhook() {
   if [ ! "$(oc get ValidatingWebhookConfiguration "edp-codebase-operator-validating-webhook-configuration-${edp_project}" --ignore-not-found| wc -c)" -eq 0 ];then
     oc get ValidatingWebhookConfiguration "edp-codebase-operator-validating-webhook-configuration-${edp_project}" -o yaml > codebase_webhook.yaml
     oc delete -f codebase_webhook.yaml
   else
     if [ -f ./codebase_webhook.yaml ];then
       oc apply -f codebase_webhook.yaml
       rm -rf codebase_webhook.yaml
     fi
   fi
}

restore() {
    replica_count=""

    echo "Start restoring deployment application with label - ${3}"
    velero create restore "${1}-${execution_time}-${5}" --selector "${3}" --from-backup "${1}"

    timeout 200 bash -c 'while [[ ! $(oc get deployment -l '${3}' -n '${4}' --no-headers -o name) ]]; do sleep 10; echo "Waiting for deployment - '${3}'"; done'
    replica_count=$(oc get deployment -l "${3}" -n "${4}" -o jsonpath='{.items[0].spec.replicas}' --ignore-not-found)

    if [ -n "${replica_count}" ] && [ "${cloud_provider}" != "AWS" ]; then
      deployment_pod_name=$(oc get pods -l "${3}" -n "${4}" -o json | jq -c '.items[] | select( .metadata.ownerReferences != null ) |.metadata.name' | tr -d '"')
      restic_pod_name=$(oc get pods -l "${3}" -o=jsonpath="{range .items[*]}{.metadata.name},{.spec.initContainers[*].name}{'\n'}{end}" -n "${4}" | grep "restic-wait" | awk -F, '{ print $1 }')
      if [[ "${deployment_pod_name}" != "${restic_pod_name}" ]]; then
        oc scale deployment -l "${3}" -n "${4}" --replicas 0
        oc delete pod "${deployment_pod_name}" -n "${4}" --grace-period=0 --force=true --ignore-not-found=true
      fi
      echo "Waiting for Restic pod in pod ${restic_pod_name}"
      restic_wait "${restic_pod_name}" "${4}"
      sleep 5
      oc scale deployment -l "${3}" -n "${4}" --replicas "${replica_count}"
    fi

    sleep 30

    echo "Delete pods with label ${3}. Root cause: network issue"
    oc delete pod -l "${3}" -n "${4}" --wait=true
    echo "[DEBUG]Restic restore done for label - ${3}, pod in Running state"
}

minio_resources "create"

codebase_webhook

delete_namespace

echo "Initing restore"
velero restore create --from-backup "${backup_name}" --include-resources secrets,configmaps --wait

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

mkdir -p "${resources_folder}"

rclone copy "minio:/${minio_backup_bucket_name}/openshift-backups/backups/${backup_name}/openshift-resources" ${resources_folder}

for resource_name in "${crds_to_patch[@]}";do
    oc patch "${resource_type}" "${resource_name}" --type='json' -p='[{"op":"replace","path":"/spec/versions/0/subresources","value":null}]'
done

for op_object in "${resources_folder}"/*; do
  [[ -e "${op_object}" ]] || break
  oc apply -f "${op_object}";
done

codebase_webhook

for resource_name in "${crds_to_patch[@]}";do
    oc patch "${resource_type}" "${resource_name}" --type='json' -p='[{"op":"add","path":"/spec/versions/0/subresources","value":{"status":{}}}]'
done

rm -rf "${resources_folder}"

oc adm policy add-scc-to-user anyuid -z jenkins -n "${edp_project}"
oc adm policy add-scc-to-user anyuid -z istio-ingressgateway-control-plane-main-service-account -n "${edp_project}"

for object in "${animals[@]}"; do
  type=$(echo "${object}" | awk -F, '{ print $1 }')
  label=$(echo "${object}" | awk -F, '{ print $2 }')
  resource_name=$(echo "${object}" | awk -F, '{ print $3 }')
  restore "${backup_name}" "${type}" "${label}" "${edp_project}" "${resource_name}"
done

echo "[DEBUG] Finish restoring process"
velero create restore --from-backup "${backup_name}" --exclude-resources secrets,configmaps,persistentvolumes,persistentvolumeclaims,roles,rolebindings,clusterrolebindings,clusterroles,podsecuritypolicies --wait

sleep 120 && oc delete pod -n "${edp_project}" -l name=jenkins-operator && sleep 120

minio_resources "delete"
{{- end }}
