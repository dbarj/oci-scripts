#!/bin/bash
#************************************************************************
#
#   oci_network_seclist_clone_rules.sh - Replicate SecList rules from one
#   Security List to another.
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

#### Export the following variables to control this tool
## OCI_CLONE_SOURCE_REGION
# -> Specify if want to use a non-default region for the Source SecList.
# eg: export OCI_CLONE_SOURCE_REGION="us-ashburn-1"
## OCI_CLONE_TARGET_REGION
# -> Specify if want to use a non-default region for the Target SecList.
# eg: export OCI_CLONE_TARGET_REGION="us-phoenix-1"
## OCI_CLONE_SEDREP_VCN_NAME
# -> Specify if want to use a sed replace rule to convert the Source VCN Name into the Target. If empty and not specified in parametes, the same name will be used.
# eg: export OCI_CLONE_SEDREP_VCN_NAME="s/ash/phx/g"
## OCI_CLONE_SEDREP_SEC_NAME
# -> Specify if want to use a sed replace rule to convert the Source SecList Name into the Target. If empty and not specified in parametes, the same name will be used.
# eg: export OCI_CLONE_SEDREP_SEC_NAME="s/ash/phx/g"
## OCI_CLONE_SEDREP_RULES
# -> Specify if want to use a sed replace rule to convert the SecList rules into the Target. If empty and not specified in parametes, the same name will be used.
# eg: export OCI_CLONE_SEDREP_RULES="s/\"10\.72\./\"10.XXX./g; s/\"10\.73\./\"10.72./g; s/\"10\.XXX\./\"10.73./g;"
# This will exchange 10.72. <-> 10.73.
################################################

#### INTERNAL
[ -n "${OCI_CLONE_SOURCE_REGION}" ]   && v_source_region="${OCI_CLONE_SOURCE_REGION}"
[ -n "${OCI_CLONE_TARGET_REGION}" ]   && v_target_region="${OCI_CLONE_TARGET_REGION}"
[ -n "${OCI_CLONE_SEDREP_SEC_NAME}" ] && v_target_sl_name_sedrep_rule="${OCI_CLONE_SEDREP_SEC_NAME}"
[ -n "${OCI_CLONE_SEDREP_VCN_NAME}" ] && v_target_vcn_name_sedrep_rule="${OCI_CLONE_SEDREP_VCN_NAME}"
[ -n "${OCI_CLONE_SEDREP_RULES}" ]    && v_target_sl_rules_sedrep_rule="${OCI_CLONE_SEDREP_RULES}"
####

# Define paths for oci-cli and jq or put them on $PATH. Don't use relative PATHs in the variables below.
v_oci="oci"
v_jq="jq"

# Add any desired oci argument. Keep default to avoid oci_cli_rc usage (recommended).
v_oci_args="--cli-rc-file /dev/null"

# Don't change it.
v_min_ocicli="2.4.30"

function echoError ()
{
  (>&2 echoStatus "$1" "RED")
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
  echoError "$1"
  ( set -o posix ; set ) > /tmp/oci_debug.$(date '+%Y%m%d%H%M%S').txt
  exit 1
}

if [ $# -lt 1 -o $# -gt 4 ]
then
  echoStatus "At least 1 argument is needed.. given: $#"
  echoStatus "- 1st param = Source Security List Name or OCID"
  echoStatus "- 2nd param = Source VCN Name or OCID. Optional if first parameter is OCID, not a name."
  echoStatus "- 3rd param = Target Security List Name or OCID (Optional). If not provided, same name or internal transformation will be applied."
  echoStatus "- 4th param = Target VCN Name or OCID (Optional). If not provided, same name or internal transformation will be applied."
  exit 1
fi

v_sl_name_source="$1"
v_vcn_name_source="$2"
v_sl_name_target="$3"
v_vcn_name_target="$4"

[ -n "$v_sl_name_source" ] || exitError "Source Security List Name or OCID can't be null."

[ "${v_sl_name_source:0:22}" != "ocid1.securitylist.oc1" -a -z "$v_vcn_name_source" ] && exitError "Source VCN Name or OCID can't be null when source SL OCID is not provided."
#[ "${v_sl_name_target:0:22}" != "ocid1.securitylist.oc1" -a -z "${v_vcn_name_target}" -a -z "${v_vcn_name_source}" ] && exitError "Source VCN Name or OCID can't be null when both target SL and target VCN are not provided."
[ -z "${v_sl_name_target}" -a -z "${v_vcn_name_target}" -a "${v_source_region}" == "${v_target_region}" -a -z "${v_target_sl_name_sedrep_rule}" -a -z "${v_target_vcn_name_sedrep_rule}" ] && exitError "Source and Target are the same."

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

#### Validade OCI-CLI and PARAMETERS

v_test=$(${v_oci} iam compartment list --all 2>&1) && ret=$? || ret=$?
if [ $ret -ne 0 ]
then
  echoError "oci-cli not able to run \"${v_oci} iam compartment list --all\". Please check error:"
  echoError "$v_test"
  exit 1
fi

function getVCN ()
{
  v_vcnID=""
  v_vcn_name="$1"
  local v_vcn_region="$2"
  if [ "${v_vcn_name:0:13}" == "ocid1.vcn.oc1" ]
  then
    v_jsonVCN=$(${v_oci} network vcn get --vcn-id "${v_vcn_name}" | ${v_jq} -rc '.data | select(."lifecycle-state" == "AVAILABLE")') && ret=$? || ret=$?
    [ $ret -eq 0 -a -n "$v_jsonVCN" ] || exitError "Could not find a VCN with the provided OCID in ${v_vcn_region} region."
    v_vcnID=$(echo "$v_jsonVCN" | ${v_jq} -rc '."id"')
    v_vcn_name=$(echo "$v_jsonVCN" | ${v_jq} -rc '."display-name"') && ret=$? || ret=$?
    [ $ret -eq 0 -a -n "$v_vcn_name" ] || exitError "Could not get Display Name of VCN ${v_vcnID} in ${v_vcn_region} region."
  else
    v_list_comps=$(${v_oci} iam compartment list --all | ${v_jq} -rc '.data[]."id"') && ret=$? || ret=$?
    [ $ret -eq 0 -a -n "$v_list_comps" ] || exitError "Could not list Compartments in ${v_vcn_region} region."
    for v_comp in $v_list_comps
    do
      v_out=$(${v_oci} network vcn list --compartment-id "$v_comp" --all | ${v_jq} -rc '.data[] | select(."display-name" == "'"${v_vcn_name}"'" and ."lifecycle-state" == "AVAILABLE") | ."id"') && ret=$? || ret=$?
      [ $ret -eq 0 ] || exitError "Could not search the OCID of VCN ${v_vcn_name} in compartment ${v_comp} in ${v_vcn_region} region. Use OCID instead."
      if [ -n "$v_out" ]
      then
        [ -z "$v_vcnID" ] || exitError "More than 1 VCN named \"${v_vcn_name}\" found in this Tenancy in ${v_vcn_region} region. Use OCID instead."
        [ -n "$v_vcnID" ] || v_vcnID="$v_out"
      fi
    done
    if [ -z "$v_vcnID" ]
    then
      exitError "Could not get OCID of VCN ${v_vcn_name} in ${v_vcn_region} region."
    elif [ $(echo "$v_vcnID" | wc -l) -ne 1 ]
    then
      exitError "More than 1 VCN named \"${v_vcn_name}\" found in one Compartment in ${v_vcn_region} region. Use OCID instead."
    fi
    v_jsonVCN=$(${v_oci} network vcn get --vcn-id "${v_vcnID}" | ${v_jq} -rc '.data')
  fi
}

function getSL ()
{
  v_sl_name="$1"
  local v_sl_region="$2"
  local v_vcnID="$3"
  local v_compartment_id="$4"
  if [ "${v_sl_name:0:22}" == "ocid1.securitylist.oc1" ]
  then
    v_jsonSL=$(${v_oci} network security-list get --security-list-id "${v_sl_name}" | ${v_jq} -rc '.data | select(."lifecycle-state" == "AVAILABLE")') && ret=$? || ret=$?
    [ $ret -eq 0 -a -n "$v_jsonSL" ] || exitError "Could not find a SL with the provided OCID in ${v_sl_region} region."
    v_slID=$(echo "$v_jsonSL" | ${v_jq} -rc '."id"')
    v_sl_name=$(echo "$v_jsonSL" | ${v_jq} -rc '."display-name"') && ret=$? || ret=$?
    [ $ret -eq 0 -a -n "$v_sl_name" ] || exitError "Could not get Display Name of SL ${v_slID} in ${v_sl_region} region."
  else
    v_jsonSL=$(${v_oci} network security-list list --vcn-id $v_vcnID --compartment-id "$v_compartment_id" --all | ${v_jq} -rc '.data[] | select(."display-name" == "'"${v_sl_name}"'" and ."lifecycle-state" == "AVAILABLE")') && ret=$? || ret=$?
    [ $ret -eq 0 -a -n "$v_jsonSL" ] || exitError "Could not search the OCID of SL ${v_sl_name} in compartment ${v_comp} in ${v_sl_region} region. Use OCID instead."
    v_slID=$(echo "$v_jsonSL" | ${v_jq} -rc '."id"')
    if [ -z "$v_slID" ]
    then
      exitError "Could not get OCID of SL ${v_sl_name} in ${v_sl_region} region."
    elif [ $(echo "$v_slID" | wc -l) -ne 1 ]
    then
      exitError "More than 1 SL named \"${v_sl_name}\" found in one Compartment in ${v_sl_region} region. Use OCID instead."
    fi
  fi
}

function getSourceSL ()
{
  getSL "${v_sl_name_source}" "source" "$v_vcnID_source" "$v_compartment_id_source"
  v_sl_name_source="$v_sl_name"
  v_slID_source="$v_slID"
  v_jsonSL_source="$v_jsonSL"
  v_vcnID_source=$(echo "$v_jsonSL_source" | ${v_jq} -rc '."vcn-id"') && ret=$? || ret=$?
  [ $ret -eq 0 -a -n "$v_vcnID_source" ] || exitError "Could not get the VCN ID in source region."
}

function getTargetSL ()
{
  getSL "${v_sl_name_target}" "target" "$v_vcnID_target" "$v_compartment_id_target"
  v_sl_name_target="$v_sl_name"
  v_slID_target="$v_slID"
  v_jsonSL_target="$v_jsonSL"
  v_vcnID_target=$(echo "$v_jsonSL_target" | ${v_jq} -rc '."vcn-id"') && ret=$? || ret=$?
  [ $ret -eq 0 -a -n "$v_vcnID_target" ] || exitError "Could not get the VCN ID in target region."
}

function getSourceVCN ()
{
  getVCN "${v_vcn_name_source}" "source"
  v_vcnID_source="$v_vcnID"
  v_jsonVCN_source="$v_jsonVCN"
  v_vcn_name_source="$v_vcn_name"
  v_compartment_id_source=$(echo "$v_jsonVCN_source" | ${v_jq} -rc '."compartment-id"') && ret=$? || ret=$?
  [ $ret -eq 0 -a -n "$v_compartment_id_source" ] || exitError "Could not get the VCN Compartment ID in source region."
}

function getTargetVCN ()
{
  getVCN "${v_vcn_name_target}" "target"
  v_vcnID_target="$v_vcnID"
  v_jsonVCN_target="$v_jsonVCN"
  v_vcn_name_target="$v_vcn_name"
  v_compartment_id_target=$(echo "$v_jsonVCN_target" | ${v_jq} -rc '."compartment-id"') && ret=$? || ret=$?
  [ $ret -eq 0 -a -n "$v_compartment_id_target" ] || exitError "Could not get the VCN Compartment ID in target region."
}

#### BEGIN

## Check Source

setRetion "${v_source_region}"

if [ "${v_sl_name_source:0:22}" != "ocid1.securitylist.oc1" ]
then
  # If OCID of SL is not defined, will need to get VCN info
  getSourceVCN
fi

getSourceSL

if [ "${v_sl_name_target:0:22}" != "ocid1.securitylist.oc1" -a -z "${v_vcn_name_target}" -a \( "${v_vcn_name_source:0:13}" == "ocid1.vcn.oc1" -o -z "${v_vcn_name_source}" \) ]
then
  # Will also need the source VCN info (basically the name) if target VCN is empty, as transformation will be required.
  v_vcn_name_source="${v_vcnID_source}"
  getSourceVCN
fi

## Check Target

setRetion "${v_target_region}"

if [ "${v_sl_name_target:0:22}" != "ocid1.securitylist.oc1" ]
then
  if [ -z "${v_vcn_name_target}" ]
  then
    v_vcn_name_target="${v_vcn_name_source}"
    [ -n "${v_target_vcn_name_sedrep_rule}" ] && v_vcn_name_target=$(echo "${v_vcn_name_source}" | sed "${v_target_vcn_name_sedrep_rule}")
    echoStatus "Target VCN will be ${v_vcn_name_target}"
  fi
  # If OCID of SL is not defined, will need to get VCN info
  getTargetVCN
fi

if [ -z "${v_sl_name_target}" ]
then
  v_sl_name_target="${v_sl_name_source}"
  [ -n "${v_target_sl_name_sedrep_rule}" ] && v_sl_name_target=$(echo "${v_sl_name_source}" | sed "${v_target_sl_name_sedrep_rule}")
  echoStatus "Target SL will be ${v_sl_name_target}"
fi

getTargetSL

# Security Check
[ "${v_slID_source}" == "${v_slID_target}" ] && exitError "Source and Target are the same."

v_jason_i=$(echo "$v_jsonSL_source" | jq -rc '."ingress-security-rules"')
v_jason_e=$(echo "$v_jsonSL_source" | jq -rc '."egress-security-rules"')

[ -z "$v_target_sl_rules_sedrep_rule" ] && v_target_sl_rules_sedrep_rule="s/x/x/"
v_jason_i=$(echo "$v_jason_i" | sed "$v_target_sl_rules_sedrep_rule")
v_jason_e=$(echo "$v_jason_e" | sed "$v_target_sl_rules_sedrep_rule")

v_params=()
v_params+=(--force)
v_params+=(--security-list-id  ${v_slID_target})
v_params+=(--ingress-security-rules "$v_jason_i")
v_params+=(--egress-security-rules  "$v_jason_e")
v_out=$(${v_oci} network security-list update "${v_params[@]}") && ret=$? || ret=$?

[ $ret -eq 0 ] || exitError "SL ${v_sl_name_target} update failed."
[ $ret -ne 0 ] || echoStatus "SL ${v_sl_name_target} updated!" "BOLD"

exit $ret
###
