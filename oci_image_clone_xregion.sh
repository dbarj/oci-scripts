#!/bin/bash
#************************************************************************
#
#   oci_image_clone_xregion.sh - Move a compute image from one region
#   to another region.
#
#   Copyright 2018  Rodrigo Jorge <http://www.dbarj.com.br/>
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
#************************************************************************
# Available at: https://github.com/dbarj/oci-scripts
# Created on: Aug/2018 by Rodrigo Jorge
# Version 1.02
#************************************************************************
set -e

[ -n "${v_step}" ] || v_step=1

read -r -d '' v_all_steps << EOM || true
## Macro Steps
# $(printf "%02d\n" $((v_step+0))) - Export the Image.
# $(printf "%02d\n" $((v_step+1))) - Create Pre-Auth URL.
# $(printf "%02d\n" $((v_step+2))) - Import the Image in target region.
# $(printf "%02d\n" $((v_step+3))) - Remove exported Image object.
# $(printf "%02d\n" $((v_step+4))) - Remove Pre-Auth URL.
EOM

#### INTERNAL
v_source_region="us-ashburn-1"
v_target_region="us-phoenix-1"
v_os_bucket=""
####

# Define paths for oci-cli and jq or put them on $PATH. Don't use relative PATHs in the variables below.
v_oci="oci"
v_jq="jq"

# Add any desired oci argument. Keep default to avoid oci_cli_rc usage (recommended).
v_oci_args="--cli-rc-file /dev/null"

# Don't change it.
v_min_ocicli="2.4.30"

echoError ()
{
   (>&2 echo "$1")
}

exitError ()
{
   echoError "$1"
   exit 1
}

if [ $# -ne 1 -a $# -ne 2 ]
then
  echoError "$0: One or two arguments are needed.. given: $#"
  echoError "- 1st param = Image Name or OCID"
  echoError "- 2nd param = Object Storage Bucket (Optional)"
  exit 1
fi

v_image_name="$1"

[ -n "$v_image_name" ] || exitError "Image Name or OCID can't be null."
[ -n "$2" ] && v_os_bucket="$2"

if ! $(which ${v_oci} >&- 2>&-)
then
  echoError "Could not find oci-cli binary. Please adapt the path in the script if not in \$PATH."
  echoError "Dowload page: https://github.com/oracle/oci-cli"
  exit 1
fi

if ! $(which ${v_jq} >&- 2>&-)
then
  echoError "Could not find jq binary. Please adapt the path in the script if not in \$PATH."
  echoError "Download page: https://github.com/stedolan/jq/releases"
  exit 1
fi

v_cur_ocicli=$(${v_oci} -v)

if [ "${v_min_ocicli}" != "`echo -e "${v_min_ocicli}\n${v_cur_ocicli}" | sort -V | head -n1`" ]
then
  exitError "Minimal oci version required is ${v_min_ocicli}. Found: ${v_cur_ocicli}"
fi

v_ocicli_timeout=1200

[ -z "${v_oci_args}" ] || v_oci="${v_oci} ${v_oci_args}"
v_oci_orig="${v_oci}"

setRetion ()
{
  # Receive region argument and set as oci-cli parameter
  v_oci="$v_oci_orig"
  [ -n "$1" ] && v_oci="${v_oci} --region $1"
}

#### BEGIN

setRetion "${v_source_region}"

#### Validade OCI-CLI and PARAMETERS

v_test=$(${v_oci} iam compartment list --all 2>&1) && ret=$? || ret=$?
if [ $ret -ne 0 ]
then
  echoError "oci-cli not able to run \"${v_oci} iam compartment list --all\". Please check error:"
  echoError "$v_test"
  exit 1
fi

if [ -z "$v_os_bucket" ]
then
  echoError "A pre-created object storage bucket is required for image migration across regions."
  echoError "Create one and pass it as 2nd parameter or define the variable v_os_bucket inside the script."
  exit 1
fi

v_os_ns=$(${v_oci} os ns get | ${v_jq} -rc '."data"') && ret=$? || ret=$?
[ $ret -eq 0 -a -n "$v_os_ns" ] || exitError "Could not get the namespace for this tenancy."

v_test=$(${v_oci} os bucket get --namespace-name "${v_os_ns}" --bucket-name "${v_os_bucket}" 2>&1) && ret=$? || ret=$?
if [ $ret -ne 0 ]
then
  echoError "Could not find bucket \"${v_os_bucket}\"."
  exit 1
fi

if [ "${v_image_name:0:15}" == "ocid1.image.oc1" ]
then
  v_image_ID=$(${v_oci} compute image get --image-id "${v_image_name}" | ${v_jq} -rc '.data | select(."lifecycle-state" == "AVAILABLE") | ."id"') && ret=$? || ret=$?
  [ $ret -eq 0 -a -n "$v_image_ID" ] || exitError "Could not find an image with the provided OCID."
  v_image_name=$(${v_oci} compute image get --image-id "${v_image_ID}" | ${v_jq} -rc '.data."display-name"') && ret=$? || ret=$?
  [ $ret -eq 0 -a -n "$v_image_name" ] || exitError "Could not get Display Name of image ${v_image_ID}"
else
  v_list_comps=$(${v_oci} iam compartment list --all | ${v_jq} -rc '.data[]."id"') && ret=$? || ret=$?
  [ $ret -eq 0 -a -n "$v_list_comps" ] || exitError "Could not list Compartments."
  for v_comp in $v_list_comps
  do
    v_out=$(${v_oci} compute image list --compartment-id "$v_comp" --all | ${v_jq} -rc '.data[] | select(."display-name" == "'"${v_image_name}"'" and ."lifecycle-state" == "AVAILABLE") | ."id"') && ret=$? || ret=$?
    [ $ret -eq 0 ] || exitError "Could not search the OCID of image ${v_image_name} in compartment ${v_comp}. Use OCID instead."
    if [ -n "$v_out" ]
    then
      [ -z "$v_image_ID" ] || exitError "More than 1 image named \"${v_image_name}\" found in this Tenancy. Use OCID instead."
      [ -n "$v_image_ID" ] || v_image_ID="$v_out"
    fi
  done
  if [ -z "$v_image_ID" ]
  then
    exitError "Could not get OCID of image ${v_image_name}"
  elif [ $(echo "$v_image_ID" | wc -l) -ne 1 ]
  then
    exitError "More than 1 image named \"${v_image_name}\" found in one Compartment. Use OCID instead."
  fi
fi

#### Collect Information

v_jsonImage=$(${v_oci} compute image get --image-id "${v_image_ID}" | ${v_jq} -rc '.data') && ret=$? || ret=$?
[ $ret -eq 0 -a -n "$v_jsonImage" ] || exitError "Could not get json for image ${v_image_name}"

v_compartment_id=$(echo "$v_jsonImage" | ${v_jq} -rc '."compartment-id"') && ret=$? || ret=$?
[ $ret -eq 0 -a -n "$v_compartment_id" ] || exitError "Could not get the image Compartment ID."
v_compartment_arg="--compartment-id ${v_compartment_id}"

printStep ()
{
  echo "Executing Step $v_step"
  ((v_step++))
}

echo "$v_all_steps"

######
###  1
######

printStep

v_os_name="${v_image_name}_IMAGE_EXPORT"

v_params=()
v_params+=(--image-id ${v_image_ID})
v_params+=(--namespace "${v_os_ns}")
v_params+=(--bucket-name "${v_os_bucket}")
v_params+=(--name "${v_os_name}")

v_jsonImageExport=$(${v_oci} compute image export to-object "${v_params[@]}") && ret=$? || ret=$?
[ $ret -eq 0 -a -n "$v_jsonImageExport" ] || exitError "Could not export Image."

while true
do
  v_jsonImage=$(${v_oci} compute image get --image-id ${v_image_ID}) && ret=$? || ret=$?
  [ $ret -eq 0 -a -n "$v_jsonImage" ] || exitError "Could not get Image status."
  v_imageStatus=$(echo "$v_jsonImage" | ${v_jq} -rc '.data."lifecycle-state"')
  [ "${v_imageStatus}" != "AVAILABLE" ] || break
  echo "Image status is ${v_imageStatus}. Please wait."
  sleep 180
done

######
###  2
######

printStep

v_preauth_name="${v_image_name}_PREAUTH"
v_preauth_expire=$(date -d '+2 day' +%Y-%m-%d)

v_params=()
v_params+=(--namespace "${v_os_ns}")
v_params+=(--bucket-name "${v_os_bucket}")
v_params+=(--object-name "${v_os_name}")
v_params+=(--name "${v_preauth_name}")
v_params+=(--access-type "ObjectRead")
v_params+=(--time-expires ${v_preauth_expire})

v_jsonPreAuthReq=$(${v_oci} os preauth-request create "${v_params[@]}") && ret=$? || ret=$?
[ $ret -eq 0 -a -n "$v_jsonPreAuthReq" ] || exitError "Could not create preauth-request."

v_preAuthID=$(echo "$v_jsonPreAuthReq" | ${v_jq} -rc '.data."id"')
v_preAuthURI=$(echo "$v_jsonPreAuthReq" | ${v_jq} -rc '.data."access-uri"')

######
###  3
######

printStep

setRetion "${v_target_region}"

v_preAuthFullURI="https://objectstorage.${v_source_region}.oraclecloud.com${v_preAuthURI}"

v_freeFormTags='{"Source_OCID":"'${v_image_ID}'"}'

v_params=()
v_params+=(${v_compartment_arg})
v_params+=(--display-name ${v_image_name})
v_params+=(--launch-mode NATIVE)
v_params+=(--source-image-type QCOW2)
v_params+=(--uri "${v_preAuthFullURI}")
v_params+=(--freeform-tags "${v_freeFormTags}")

v_jsonImageImport=$(${v_oci} compute image import from-object-uri "${v_params[@]}") && ret=$? || ret=$?
[ $ret -eq 0 -a -n "$v_jsonImageExport" ] || exitError "Could not import Image."

v_imageTargetID=$(echo "$v_jsonImageImport" | ${v_jq} -rc '.data."id"')

while true
do
  v_jsonImage=$(${v_oci} compute image get --image-id ${v_imageTargetID}) && ret=$? || ret=$?
  [ $ret -eq 0 -a -n "$v_jsonImage" ] || exitError "Could not get Image status."
  v_imageStatus=$(echo "$v_jsonImage" | ${v_jq} -rc '.data."lifecycle-state"')
  [ "${v_imageStatus}" != "AVAILABLE" ] || break
  echo "Image status is ${v_imageStatus}. Please wait."
  sleep 180
done

######
###  4
######

printStep

setRetion "${v_source_region}"

v_params=()
v_params+=(--namespace "${v_os_ns}")
v_params+=(--bucket-name "${v_os_bucket}")
v_params+=(--object-name "${v_os_name}")
v_params+=(--force)

${v_oci} os object delete "${v_params[@]}" && ret=$? || ret=$?
[ $ret -eq 0 ] || exitError "Could not delete object."

######
###  5
######

printStep

v_params=()
v_params+=(--namespace "${v_os_ns}")
v_params+=(--bucket-name "${v_os_bucket}")
v_params+=(--par-id "${v_preAuthID}")
v_params+=(--force)

${v_oci} os preauth-request delete "${v_params[@]}" && ret=$? || ret=$?
[ $ret -eq 0 ] || exitError "Could not delete preauth-request."

######

exit 0
######