#!/bin/bash
#************************************************************************
#
#   oci_image_clone_xregion.sh - Clone a compute image across Regions
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
# Version 1.05
#************************************************************************
set -eo pipefail

[ -n "${v_step}" ] || v_step=1

read -r -d '' v_all_steps << EOM || true
$(printf "%02d\n" $((v_step+0))) - Export the Image.
$(printf "%02d\n" $((v_step+1))) - Create Pre-Auth URL.
$(printf "%02d\n" $((v_step+2))) - Import the Image in target region.
$(printf "%02d\n" $((v_step+3))) - Remove exported Image object.
$(printf "%02d\n" $((v_step+4))) - Remove Pre-Auth URL.
EOM

####
#### INTERNAL - MUST BE PROVIDED HERE OR AS PARAMETERS.
####
v_os_bucket=""
v_target_region=""
v_orig_region=""
####

# Define paths for oci-cli and jq or put them on $PATH. Don't use relative PATHs in the variables below.
v_oci="oci"
v_jq="jq"

# Add any desired oci argument exporting OCI_CLI_ARGS. Keep default to avoid oci_cli_rc usage.
[ -n "${OCI_CLI_ARGS}" ] && v_oci_args="${OCI_CLI_ARGS}"
[ -z "${OCI_CLI_ARGS}" ] && v_oci_args="--cli-rc-file /dev/null"

if [ -z "${BASH_VERSION}" ]
then
  >&2 echo "Script must be executed in BASH shell."
  exit 1
fi

v_this_script="$(basename -- "$0")"

# If DEBUG variable is undefined, change to 1. Note that [-q] parameter will override this option to 0.
[[ "${DEBUG}" == "" ]] && DEBUG=1
# 0 = Only basic echo.
# 1 = Show OCI-CLI steps commands.
# 2 = Show ALL OCI-CLI commands. (TODO)

# Don't change it.
v_min_ocicli="2.6.9"

function echoError ()
{
   [ -z "$2" ] && (>&2 echo "$1") || (>&2 echoStatus "$1" "$2")
}

function echoStatus ()
{
  local RED='\033[0;31m'
  local GREEN='\033[0;32m'
  local BOLD='\033[0;1m'
  local NC='\033[0m' # No Color
  local TYPE="$GREEN"
  [ "$2" == "GREEN" ] && TYPE="$GREEN"
  [ "$2" == "RED" ] && TYPE="$RED"
  [ "$2" == "BOLD" ] && TYPE="$BOLD"
  printf "${TYPE}${1}${NC}\n"
}

function exitError ()
{
   local v_filename="${v_this_script%.*}.log"
   echoError "$1"
   ( set -o posix ; set ) > "${v_filename}"
   exit 1
}

function checkError ()
{
  # If 2 params given:
  # - If 1st is NULL, abort script printing 2nd.
  # If 3 params given:
  # - If 1st is NULL, abort script printing 3rd.
  # - If 2nd is not 0, abort script printing 3rd.
  local v_arg1 v_arg2 v_arg3
  v_arg1="$1"
  v_arg2="$2"
  v_arg3="$3"
  [ "$#" -ne 2 -a "$#" -ne 3 ] && exitError "checkError wrong usage."
  [ "$#" -eq 2 -a -z "${v_arg2}" ] && exitError "checkError wrong usage."
  [ "$#" -eq 3 -a -z "${v_arg3}" ] && exitError "checkError wrong usage."
  [ "$#" -eq 2 ] && [ -z "${v_arg1}" ] && echoStatus "${v_arg2}" "RED" && exit 1
  [ "$#" -eq 3 ] && [ -z "${v_arg1}" ] && echoStatus "${v_arg3}" "RED" && exit 1
  [ "$#" -eq 3 ] && [ "${v_arg2}" != "0" ] && echoStatus "${v_arg3}" "RED" && exit 1
  return 0
}

[ -n "$v_os_bucket" ] && v_param_os_bucket="(Optional)"
[ -n "$v_target_region" ] && v_param_target_region="(Optional)"

function printUsage ()
{
  echoError "Usage: ${v_this_script} -i <value> -b <value> -t <value> -s <value> [-q]"
  echoError ""
  echoError "-i    : Image Name or OCID"
  echoError "-b    : Object Storage Bucket ${v_param_os_bucket}"
  echoError "-t    : Target Region ${v_param_target_region}"
  echoError "-s    : Source Region"
  echoError "-q    : Quiet mode. Will suppress the spool of executed OCI-CLI commands."
  echoError ""
  echoError "Steps: "
  echoError ""
  echoError "${v_all_steps}"
  exit 1
}

while getopts ":i:b:t:s:q" opt
do
    case "${opt}" in
        i)
            v_image_name=${OPTARG}
            ;;
        b)
            v_os_bucket=${OPTARG}
            ;;
        t)
            v_target_region=${OPTARG}
            ;;
        s)
            v_orig_region=${OPTARG}
            ;;
        q)
            DEBUG=0
            ;;
        *)
            printUsage	
            ;;
    esac
done
shift $((OPTIND-1))

[ -z "$v_image_name" ] && printUsage

if [ -z "$v_os_bucket" ]
then
  echoError "A pre-created object storage bucket is required for image migration across regions."
  echoError "Create one and pass it as argument."
  exit 1
fi

[ -z "$v_target_region" ] && printUsage

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

function setRetion ()
{
  # Receive region argument and set as oci-cli parameter
  v_oci="$v_oci_orig"
  [ -n "$1" ] && v_oci="${v_oci} --region $1"
  return 0
}

function getOrigRegion ()
{
  local v_file v_region
  v_file=~/.oci/config
  if $(echo "$v_oci_args" | grep -q -i -- '--config-file')
  then
    exitError "Please specify Source Region parameter."
  fi
  if $(echo "$v_oci_args" | grep -q -i -- '--profile')
  then
    exitError "Please specify Source Region parameter."
  fi
  v_region=$(awk '/DEFAULT/{x=1}x&&/region/{print;exit}' "${v_file}" | sed 's/region=//')
  [ ! -r "${v_file}" ] && exitError "Could not read OCI config file."
  if [ -n "${v_region}" ]
  then
    echo ${v_region}
  else
    exitError "Could not get Source Region."
  fi
}

#### BEGIN

[ -z "${v_orig_region}" ] && v_orig_region=$(getOrigRegion)
setRetion "${v_orig_region}"

#### Validade OCI-CLI and PARAMETERS

v_test=$(${v_oci} iam compartment list --all 2>&1) && v_ret=$? || v_ret=$?
if [ $v_ret -ne 0 ]
then
  echoError "oci-cli not able to run \"${v_oci} iam compartment list --all\". Please check error:"
  echoError "$v_test"
  exit 1
fi

v_os_ns=$(${v_oci} os ns get | ${v_jq} -rc '."data"') && v_ret=$? || v_ret=$?
checkError "$v_os_ns" "$v_ret" "Could not get the namespace for this tenancy."

v_os_bucketJson=$(${v_oci} os bucket get --bucket-name ${v_os_bucket} | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
checkError "${v_os_bucketJson}" "$v_ret" "Could not find bucket \"${v_os_bucket}\"."

# New version is not using public OS Buckets to move anymore.
# v_os_bucketPublic=$(echo "${v_os_bucketJson}" | ${v_jq} -rc '."public-access-type"')
# checkError "${v_os_bucketPublic}" "Can't get Bucket public attribute."
# [ "${v_os_bucketPublic}" == "NoPublicAccess" ] && exitError "OS Bucket must have Public ObjectRead Access enabled."

if [ "${v_image_name:0:15}" == "ocid1.image.oc1" ]
then
  v_image_ID=$(${v_oci} compute image get --image-id "${v_image_name}" | ${v_jq} -rc '.data | select(."lifecycle-state" == "AVAILABLE") | ."id"') && v_ret=$? || v_ret=$?
  checkError "$v_image_ID" "$v_ret" "Could not find an image with the provided OCID."
  v_image_name=$(${v_oci} compute image get --image-id "${v_image_ID}" | ${v_jq} -rc '.data."display-name"') && v_ret=$? || v_ret=$?
  checkError "$v_image_name" "$v_ret" "Could not get Display Name of image ${v_image_ID}"
else
  v_list_comps=$(${v_oci} iam compartment list --all | ${v_jq} -rc '.data[]."id"') && v_ret=$? || v_ret=$?
  checkError "$v_list_comps" "$v_ret" "Could not list Compartments."
  for v_comp in $v_list_comps
  do
    v_out=$(${v_oci} compute image list --compartment-id "$v_comp" --all | ${v_jq} -rc '.data[] | select(."display-name" == "'"${v_image_name}"'" and ."lifecycle-state" == "AVAILABLE") | ."id"') && v_ret=$? || v_ret=$?
    checkError "x" "$v_ret" "Could not search the OCID of image ${v_image_name} in compartment ${v_comp}. Use OCID instead."
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

v_orig_imageJson=$(${v_oci} compute image get --image-id "${v_image_ID}" | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
checkError "$v_orig_imageJson" "$v_ret" "Could not get json for image ${v_image_name}"

v_compartment_id=$(echo "$v_orig_imageJson" | ${v_jq} -rc '."compartment-id"') && v_ret=$? || v_ret=$?
checkError "$v_compartment_id" "$v_ret" "Could not get the image Compartment ID."

v_compartment_arg="--compartment-id ${v_compartment_id}"

v_orig_OS=$(echo "$v_orig_imageJson" | ${v_jq} -rc '."operating-system"')
checkError "$v_orig_OS" "Could not get Image OS."
[ "${v_orig_OS}" == "Windows" ] && exitError "Cloning Oracle Windows based compute instances is not yet supported by OCI-CLI."


printStep ()
{
  echoStatus "Executing Step $v_step"
  ((v_step++))
}

[ "${v_step}" -eq 1 ] && echoStatus "Starting execution."
echo "Steps:"
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

(( $DEBUG )) && set -x
v_jsonImageExport=$(${v_oci} compute image export to-object "${v_params[@]}") && v_ret=$? || v_ret=$?
(( $DEBUG )) && set +x
checkError "$v_jsonImageExport" "$v_ret" "Could not export Image."

while true
do
  v_jsonImage=$(${v_oci} compute image get --image-id ${v_image_ID}) && v_ret=$? || v_ret=$?
  checkError "$v_jsonImage" "$v_ret" "Could not get Image status."
  v_imageStatus=$(echo "$v_jsonImage" | ${v_jq} -rc '.data."lifecycle-state"')
  [ "${v_imageStatus}" == "AVAILABLE" ] && break
  [ "${v_imageStatus}" == "DELETED" ] && exitError "Image Status is DELETED."
  echo "Image status is ${v_imageStatus}. Please wait."
  sleep 180
done

######
###  2
######

printStep

v_preauth_name="${v_image_name}_PREAUTH"

case "$(uname -s)" in
    Linux*)     v_preauth_expire=$(date -d '+2 day' +%Y-%m-%d);;
    Darwin*)    v_preauth_expire=$(date -v+2d +%Y-%m-%d);;
    *)          v_preauth_expire=$(date +%Y-%m-%d)
esac

v_params=()
v_params+=(--namespace "${v_os_ns}")
v_params+=(--bucket-name "${v_os_bucket}")
v_params+=(--object-name "${v_os_name}")
v_params+=(--name "${v_preauth_name}")
v_params+=(--access-type "ObjectRead")
v_params+=(--time-expires ${v_preauth_expire})

(( $DEBUG )) && set -x
v_jsonPreAuthReq=$(${v_oci} os preauth-request create "${v_params[@]}") && v_ret=$? || v_ret=$?
(( $DEBUG )) && set +x
checkError "$v_jsonPreAuthReq" "$v_ret" "Could not create preauth-request."

v_preAuthID=$(echo "$v_jsonPreAuthReq" | ${v_jq} -rc '.data."id"')
v_preAuthURI=$(echo "$v_jsonPreAuthReq" | ${v_jq} -rc '.data."access-uri"')

######
###  3
######

printStep

setRetion "${v_target_region}"

v_preAuthFullURI="https://objectstorage.${v_orig_region}.oraclecloud.com${v_preAuthURI}"

v_freeFormTags='{"Source_OCID":"'${v_image_ID}'"}'
v_launchMode=$(echo "$v_orig_imageJson" | ${v_jq} -rc '."launch-mode"')

v_params=()
v_params+=(${v_compartment_arg})
v_params+=(--display-name ${v_image_name})
v_params+=(--launch-mode ${v_launchMode})
v_params+=(--source-image-type QCOW2)
v_params+=(--uri "${v_preAuthFullURI}")
v_params+=(--freeform-tags "${v_freeFormTags}")

(( $DEBUG )) && set -x
v_jsonImageImport=$(${v_oci} compute image import from-object-uri "${v_params[@]}") && v_ret=$? || v_ret=$?
(( $DEBUG )) && set +x
checkError "$v_jsonImageImport" "$v_ret" "Could not import Image."

v_imageTargetID=$(echo "$v_jsonImageImport" | ${v_jq} -rc '.data."id"') && v_ret=$? || v_ret=$?
checkError "$v_imageTargetID" "$v_ret" "Could not get imported Image ID."

while true
do
  v_jsonImage=$(${v_oci} compute image get --image-id ${v_imageTargetID}) && v_ret=$? || v_ret=$?
  checkError "$v_jsonImage" "$v_ret" "Could not get Image status."
  v_imageStatus=$(echo "$v_jsonImage" | ${v_jq} -rc '.data."lifecycle-state"')
  [ "${v_imageStatus}" == "AVAILABLE" ] && break
  [ "${v_imageStatus}" == "DELETED" ] && exitError "Image Status is DELETED."
  echo "Image status is ${v_imageStatus}. Please wait."
  sleep 180
done

######
###  4
######

printStep

setRetion "${v_orig_region}"

v_params=()
v_params+=(--namespace "${v_os_ns}")
v_params+=(--bucket-name "${v_os_bucket}")
v_params+=(--object-name "${v_os_name}")
v_params+=(--force)

(( $DEBUG )) && set -x
${v_oci} os object delete "${v_params[@]}" && v_ret=$? || v_ret=$?
(( $DEBUG )) && set +x
checkError "x" "$v_ret" "Could not delete object."

######
###  5
######

printStep

v_params=()
v_params+=(--namespace "${v_os_ns}")
v_params+=(--bucket-name "${v_os_bucket}")
v_params+=(--par-id "${v_preAuthID}")
v_params+=(--force)

(( $DEBUG )) && set -x
${v_oci} os preauth-request delete "${v_params[@]}" && v_ret=$? || v_ret=$?
(( $DEBUG )) && set +x
checkError "x" "$v_ret" "Could not delete preauth-request."

######

exit 0
######