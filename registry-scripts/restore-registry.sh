#!/usr/bin/env bash

registry_name="$1"
edp_ns="$2"
backup_name="$3"
execution_time="$4"
resource_folder="/tmp/openshift-resources"
runtime_jenkins_access_folder="${resource_folder}/jenkins_access"
KAFKA_DISK_SIZE_EXTENSION_SIZE=40

declare -a openshift_resources=("service" "gerrits" "jenkins")
declare -a animals=("statefulset,app.kubernetes.io/name=vault,vault"
  "deployment,app=nexus,nexus"
  "deployment,app=gerrit,gerrit"
  "deployment,app=jenkins,jenkins"
  "statefulset,postgres-operator.crunchydata.com/cluster=operational,crunchy-operational"
  "statefulset,postgres-operator.crunchydata.com/cluster=analytical,crunchy-analitycal"
  "statefulset,strimzi.io/name=kafka-cluster-kafka,kafka-cluster-kafka"
  "statefulset,strimzi.io/name=kafka-cluster-zookeeper,kafka-cluster-kafka-zookeeper"
  "statefulset,app.kubernetes.io/component=redis,redis"
  "statefulset,app=redis-admin,redash-redis-viewer"
  "statefulset,app=redis-viewer,redis-viewer"
  "deployment,app.kubernetes.io/instance=geo-server,geo-server"
)

restoreObjectFromMinio() {
  for resource in "${1}"/*.yaml; do
    oc apply -f "${resource}"
  done
}
restic_wait() {
  while [[ $(oc get pods "${1}" -o 'jsonpath={..status.conditions[?(@.type=="Initialized")].status}' -n "${2}") != "True" ]]; do
    sleep 10
    echo "Restic is not initialized in pod ${1}"
  done
}

restore_crunchy_ownerref() {
  uid=$(oc -n "${registry_name}" get postgrescluster "${1}" -o jsonpath='{.metadata.uid}')
  for resourceKind in "role" "rolebinding" "serviceAccount"; do
    for postfix in "instance" "pgbackrest"; do
      oc -n "${registry_name}" patch "${resourceKind}/${1}-${postfix}" -p '{"metadata": {"ownerReferences":[{"apiVersion": "postgres-operator.crunchydata.com/v1beta1","kind": "PostgresCluster","name": "'${1}'","uid": "'${uid}'","controller": true,"blockOwnerDeletion": true}]}}'
    done
  done
}

restore() {
  REPLICA_COUNT=""
  if [[ "${2}" == "statefulset" ]]; then
    echo "Start restoring stateful application with label - $3"
    velero create restore "${1}-${execution_time}-${5}" --selector "${3}" --from-backup "${1}" --wait
    for pod_name in $(oc get pods -l "${3}" -o custom-columns='NAME:.metadata.name' --no-headers -n "${4}"); do
      echo "Waiting for Restic pod in pod ${pod_name}"
      restic_wait "${pod_name}" "${4}"
      sleep 5
    done
  elif [[ "${2}" == "deployment" ]]; then
    echo "Start restoring deployment application with label - $3"
    velero create restore "${1}-${execution_time}-${5}" --selector "${3}" --from-backup "${1}"
    timeout 200 bash -c 'while [[ ! $(oc get deployment -l '${3}' -n '${4}' --no-headers -o name) ]]; do sleep 10; echo "Waiting for deployment - '${3}'"; done'
    REPLICA_COUNT=$(oc get deployment -l ${3} -n ${4} -o jsonpath='{.items[0].spec.replicas}' --ignore-not-found)
    if [ -n "${REPLICA_COUNT}" ]; then
      deployment_pod_name=$(oc get pods -l $3 -n $4 -o json | jq -c '.items[] | select( .metadata.ownerReferences != null ) |.metadata.name' | tr -d '"')
      restic_pod_name=$(oc get pods -l "${3}" -o=jsonpath="{range .items[*]}{.metadata.name},{.spec.initContainers[*].name}{'\n'}{end}" -n "${4}" | grep "restic-wait" | awk -F, '{ print $1 }')
      if [[ "${deployment_pod_name}" != "${restic_pod_name}" ]]; then
        oc scale deployment -l ${3} -n ${4} --replicas 0
        oc delete pod "${deployment_pod_name}" -n ${4} --grace-period=0 --force=true --ignore-not-found=true
      fi
      echo "Waiting for Restic pod in pod ${restic_pod_name}"
      restic_wait "${restic_pod_name}" "${4}"
      sleep 5
      if [[ "${3}" == "app=jenkins" ]]; then
        echo "Additional steps for restoring $3. Cause: Jenkins URL not changed after restoring in Openshift"
        oc -n "${4}" cp registry-scripts/scripts/change_url.groovy "${restic_pod_name}:/var/lib/jenkins/init.groovy.d/change_url.groovy" -c jenkins
      fi
      oc scale deployment -l ${3} -n "${4}" --replicas ${REPLICA_COUNT}
    fi
  fi

  echo "Delete pods with label ${3}. Root cause: network issue"
  oc delete pod -l "${3}" -n "${4}" --wait=true

  echo "Restic restore done for label - ${3}, pod in Running state"
  if [[ "${3}" == *"postgres-operator.crunchydata.com/cluster"* ]]; then
    cluster_name=$(echo "${3}" | awk -F= '{print $2}')
    echo "Additional steps for restoring $3. Cause: startup issue"
    oc apply -n "${registry_name}" -f "${resource_folder}/postgrescluster/${cluster_name}.yaml"
    restore_crunchy_ownerref "${cluster_name}"
  fi
  if [[ "${3}" == "app.kubernetes.io/component=redis" ]]; then
    echo "Additional steps for restoring $3. Cause: Redis restore specific"
    velero restore create "${1}-${execution_time}-redisfailovers" --from-backup "${1}" --include-resources redisfailovers --wait
  fi
}

echo "Getting Minio credentials"
access_key_aws=$(oc get secret/backup-credentials -n "${edp_ns}" -o jsonpath='{.data.backup-s3-like-storage-access-key-id}' | base64 -d)
access_secret_key_aws=$(oc get secret/backup-credentials -n "${edp_ns}" -o jsonpath='{.data.backup-s3-like-storage-secret-access-key}' | base64 -d)
minio_endpoint=$(oc get secret/backup-credentials -n "${edp_ns}" -o jsonpath='{.data.backup-s3-like-storage-url}' | base64 -d)
minio_bucket_name=$(oc get secret/backup-credentials -n "${edp_ns}" -o jsonpath='{.data.backup-s3-like-storage-location}' | base64 -d)

mkdir -p ~/.config/rclone
echo "Restore Openshift objects from bucket"
echo "
[minio]
type = s3
env_auth = false
access_key_id = ${access_key_aws}
secret_access_key = ${access_secret_key_aws}
endpoint = ${minio_endpoint}
region = eu-central-1
location_constraint = EU
acl = bucket-owner-full-control" >~/.config/rclone/rclone.conf

rclone delete "minio:${minio_bucket_name}/postgres-backup/${registry_name}"
rm -rf "${resource_folder}" && mkdir -p "${resource_folder}"
rclone copy "minio:${minio_bucket_name}/openshift-backups/backups/${backup_name}/openshift-resources" "${resource_folder}"

for folder in "${openshift_resources[@]}"; do
  if [ "${folder}" != "service" ]; then
    resource_crd="${folder}.v2.edp.epam.com"

    oc patch customresourcedefinition "${resource_crd}" --type='json' -p='[{"op":"replace","path":"/spec/versions/0/subresources","value":null}]'
    restoreObjectFromMinio "${resource_folder}/${folder}"
    oc patch customresourcedefinition "${resource_crd}" --type='json' -p='[{"op":"add","path":"/spec/versions/0/subresources","value":{"status":{}}}]'
  else
    restoreObjectFromMinio "${resource_folder}/${folder}"
  fi

done
echo "Delete annotation from services"
for service in $(oc get service -n "${registry_name}" --no-headers -o custom-columns=":metadata.name"); do
  oc -n "${registry_name}" annotate service "${service}" kubectl.kubernetes.io/last-applied-configuration-
done

echo "Start init restore from Velero"
time velero restore create "${backup_name}-${execution_time}-init" --from-backup "${backup_name}" --exclude-resources pods,replicasets,deployments,objectbucketclaims,deploymentconfigs,statefulsets,horizontalpodautoscalers,deamonsets,redisfailovers,kafkas,kafkaconnects,postgrescluster --wait

for pvc in $(oc -n ${registry_name} get pvc -l strimzi.io/name=kafka-cluster-kafka --no-headers -o custom-columns=NAME:.metadata.name); do
  current_size=$(oc -n ${registry_name} get pvc ${pvc} -o jsonpath='{.spec.resources.requests.storage}' | tr -dc '0-9')
  new_size=$((${current_size} + KAFKA_DISK_SIZE_EXTENSION_SIZE))
  echo "Expanding ${pvc} from ${current_size}Gi to ${new_size}Gi"
  oc -n ${registry_name} patch pvc ${pvc} --type=merge -p="{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${new_size}Gi\"}}}}"
done

oc adm policy add-role-to-user view system:serviceaccount:jenkins -n "${registry_name}"
oc adm policy add-scc-to-user anyuid system:serviceaccount:jenkins -n "${registry_name}"
oc adm policy add-scc-to-user privileged system:serviceaccount:jenkins -n "${registry_name}"

for object in "${animals[@]}"; do
  type=$(echo "${object}" | awk -F, '{ print $1 }')
  label=$(echo "${object}" | awk -F, '{ print $2 }')
  resource_name=$(echo "${object}" | awk -F, '{ print $3 }')
  restore "${backup_name}" "${type}" "${label}" "${registry_name}" "${resource_name}"
done

echo "Start restoring all others resources"
time velero restore create "${backup_name}-${execution_time}-resources" --from-backup "${backup_name}" --exclude-resources pods,routes,objectbucketclaims --wait
echo "End restoring all others resources"


echo "Restore JenkinsAuthorizationRoleMapping in registry namespace"
oc delete jenkinsauthorizationrolemapping -n "${registry_name}" --all

for jauthrolemap in "${resource_folder}"/jenkinsauthorizationrolemapping/*.yaml; do
  oc apply -f "${jauthrolemap}"
done

echo "Restore JenkinsAuthorizationRoleMapping in ${edp_ns}"
rm -rf "${runtime_jenkins_access_folder}" && mkdir -p "${runtime_jenkins_access_folder}"
pushd "${runtime_jenkins_access_folder}" || exit
for resource in $(oc get jenkinsauthorizationrolemapping -n  ${edp_ns} -o custom-columns="NAME:.metadata.name" --no-headers | grep "${registry_name}");
do
  oc get jenkinsauthorizationrolemapping -n ${edp_ns} "${resource}" -o yaml > "${resource}.yaml"
  oc delete -f "${resource}.yaml"
  oc apply -f "${resource}.yaml"
done
popd || exit

echo "Restore group for registry users"
oc delete pods -n user-management -l name=keycloak-operator

echo "Restore secret for SSO working with Openshift realm"
oc delete secret -n "${registry_name}" "keycloak-client.${registry_name}-admin.secret"
velero create restore --from-backup "${backup_name}" --include-resources secrets
oc delete pods -n "${registry_name}" -l name=keycloak-operator
echo "Force delete DSO pod"
oc delete pods -n "${registry_name}" -l app=digital-signature-ops --ignore-not-found
echo "Waiting all pods restorting"

sleep 200
