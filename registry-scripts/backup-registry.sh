#!/usr/bin/env bash

registry_name="$1"
edp_ns="$2"
ttl="$3"
backup_name="$4"
resource_folder="/tmp/openshift-resources"
declare -a openshift_registry_resources=("service" "gerrits" "jenkins" "codebases" "codebasebranches" "jenkinsauthorizationrolemapping" "postgrescluster")

access_key_aws=$(oc get secret/backup-credentials -n "${edp_ns}" -o jsonpath='{.data.backup-s3-like-storage-access-key-id}' | base64 -d)
access_secret_key_aws=$(oc get secret/backup-credentials -n "${edp_ns}" -o jsonpath='{.data.backup-s3-like-storage-secret-access-key}' | base64 -d)
minio_endpoint=$(oc get secret/backup-credentials -n "${edp_ns}" -o jsonpath='{.data.backup-s3-like-storage-url}' | base64 -d)
rook_s3_endpoint=$(oc get cephobjectstore/mdtuddm -n openshift-storage -o=jsonpath='{.status.info.endpoint}')
destination_bucket=$(oc get secret/backup-credentials -n "${edp_ns}" -o jsonpath='{.data.backup-s3-like-storage-location}' | base64 -d)

velero backup create "${backup_name}" --include-namespaces "${registry_name}" --ttl "${ttl}" --wait >/dev/null

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

rm -rf "${resource_folder}" && mkdir -p "${resource_folder}"

for object in $(oc get crd --no-headers -o custom-columns="NAME:.metadata.name" | grep keycloak); do
  kind=${object%%.*}
  if [[ ! -z $(oc get ${kind} -n ${registry_name} --no-headers -o custom-columns="NAME:.metadata.name") ]]; then
    resource_folder="${resource_folder}/${kind}"
    mkdir -p $resource_folder
    for resource_name in $(oc get ${kind} -n ${registry_name} --no-headers -o custom-columns="NAME:.metadata.name"); do
      oc get "${kind}/${resource_name}" -n "${registry_name}" -o yaml >"${resource_folder}/${resource_name}.yaml"
    done
  fi
  resource_folder="/tmp/openshift-resources"
done

for resource_kind in "${openshift_registry_resources[@]}"; do
  resource_folder="${resource_folder}/${resource_kind}"
  mkdir -p "${resource_folder}"
  for name in $(oc get "${resource_kind}" -n "${registry_name}" --no-headers -o custom-columns="NAME:.metadata.name"); do
    oc get "${resource_kind}/${name}" -n "${registry_name}" -o yaml >"${resource_folder}/${name}.yaml"
  done
  resource_folder="/tmp/openshift-resources"
done

rclone copy "${resource_folder}" "minio:/${destination_bucket}/openshift-backups/backups/${backup_name}/openshift-resources"
rm -rf "${resource_folder}"
