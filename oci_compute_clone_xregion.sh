#!/bin/bash
#************************************************************************
#
#   oci_compute_clone_xregion.sh - Clone a Compute Instance across Regions
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
# Created on: Nov/2018 by Rodrigo Jorge
# Version 1.10
#************************************************************************
set -e

# Define paths for oci-cli and jq or put them on $PATH. Don't use relative PATHs in the variables below.
v_oci="oci"
v_jq="jq"

# Add any desired oci argument. Keep default to avoid oci_cli_rc usage (recommended).
v_oci_args="--cli-rc-file /dev/null"

# Don't change it.
v_min_ocicli="2.4.40"

####
#### INTERNAL - IF NOT PROVIDED HERE OR AS PARAMETERS, WILL BE ASKED DURING CODE EXECUTION.
####
v_orig_region=""
v_target_region=""
v_clone_subnetID=""
v_target_subnetID=""
v_target_IP=""
v_target_shape=""
v_os_bucketName=""
v_sedrep_rule_target_name=""
v_script_ask="yes"
####

read -r -d '' v_all_steps << EOM || true
## Macro Steps
# 01 - Create Volume Group with instance Boot-Volume and Volumes.
# 02 - Backup Volume Group.
# 03 - Remove Volume Group.
# 04 - Create a New Boot-Volume from the Backup.
# 05 - Create a Temporary cloned Compute Instance from the Boot Volume.
# 06 - Stop the Temporary cloned Compute Instance.
# 07 - Create an Image from it.
# 08 - Remove the Temporary cloned Compute Instance and Boot-Volume.
# 09-13 - Move the image from source to target.
# 14 - Remove Image on source region.
# 15 - Create a Compute Instance from Image on target region.
# 16 - Remove Image on target region.
# 17 - Move Volumes Backups from Source Region to Target Region.
# 18 - Remove Volumes Backups in Source Region.
# 19 - Create Volumes from backups in Target Region.
# 20 - Remove Volumes Backups in Target Region.
# 21 - Attach Volumes in target.
# 22 - Run iscsiadm commands (if Linux).
EOM

function echoError ()
{
   (>&2 echo "$1")
}

function echoStatus ()
{
  local GREEN='\033[0;32m'
  local BOLD='\033[0;1m'
  local NC='\033[0m' # No Color
  local TYPE="$GREEN"
  [ "$2" == "GREEN" ] && TYPE="$GREEN"
  [ "$2" == "BOLD" ] && TYPE="$BOLD"
  printf "${TYPE}${1}${NC}\n"
}

function exitError ()
{
   echoError "$1"
   ( set -o posix ; set ) > /tmp/oci_debug.$(date '+%Y%m%d%H%M%S').txt
   exit 1
}

function checkError ()
{
  # If 2 params given:
  # - If 1st is NULL, abort script printing 2nd.
  # If 3 params given:
  # - If 1st is NULL, abort script printing 3rd.
  # - If 2nf is not 0, abort script printing 3rd.
  local v_arg1 v_arg2 v_arg3
  v_arg1="$1"
  v_arg2="$2"
  v_arg3="$3"
  [ "$#" -ne 2 -a "$#" -ne 3 ] && exitError "checkError wrong usage."
  [ "$#" -eq 2 -a -z "${v_arg2}" ] && exitError "checkError wrong usage."
  [ "$#" -eq 3 -a -z "${v_arg3}" ] && exitError "checkError wrong usage."
  [ "$#" -eq 2 ] && [ -z "${v_arg1}" ] && exitError "${v_arg2}"
  [ "$#" -eq 3 ] && [ -z "${v_arg1}" ] && exitError "${v_arg3}"
  [ "$#" -eq 3 ] && [ "${v_arg2}" != "0" ] && exitError "${v_arg3}"
  return 0
}

# trap
trap 'exitError "Code Interrupted."' INT SIGINT SIGTERM

v_orig_instName="$1"
[ -n "$2" ] && v_target_instName="$2"
[ -n "$3" ] && v_target_shape="$3"
[ -n "$4" ] && v_target_subnetID="$4"
[ -n "$5" ] && v_target_IP="$5"
[ -n "$6" ] && v_target_region="$6"
[ -n "$7" ] && v_orig_region="$7"
[ -n "$8" ] && v_os_bucketName="$8"
[ -n "$9" ] && v_clone_subnetID="$9"

if [ "${v_orig_instName:0:1}" == "-" -o "${v_orig_instName}" == "help" -o "$#" -eq 0 ]
then
  echoError "$0: All parameters, except first, are optional to run this tool."
  echoError "- 1st param = Source Compute Instance Name or OCID"
  echoError "- 2nd param = Target Compute Instance Name"
  echoError "- 3rd param = Target Compute Shape"
  echoError "- 4th param = Target Subnet ID"
  echoError "- 5th param = Target IP Address"
  echoError "- 6th param = Target Region"
  echoError "- 7th param = Source Region"
  echoError "- 8th param = Object Storage Bucket Name"
  echoError "- 9th param = Clone Subnet ID"
  exit 1
fi

[ -n "$v_orig_instName" ] || exitError "Intance Name or OCID can't be null."

if ! $(which ${v_oci} >&- 2>&-)
then
  echoError "Could not find oci-cli binary. Please adapt the path in the script if not in \$PATH."
  exitError "Dowload page: https://github.com/oracle/oci-cli"
fi

if ! $(which ${v_jq} >&- 2>&-)
then
  echoError "Could not find jq binary. Please adapt the path in the script if not in \$PATH."
  exitError "Download page: https://github.com/stedolan/jq/releases"
fi

v_oci_image_clone_script="oci_image_clone_xregion.sh"
v_workdir=$(cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P) # Folder of this script
if ! $(which "${v_workdir}"/${v_oci_image_clone_script} >&- 2>&-)
then
  echoError "This shells also use \"${v_oci_image_clone_script}\" to deal with the image migration task."
  echoError "Could not find \"${v_oci_image_clone_script}\". Please keep it in current folder."
  exitError "Download page: https://github.com/dbarj/oci-scripts"
fi

if [ "${v_script_ask}" != "yes" -a "${v_script_ask}" != "no" ]
then
  exitError "Valid values for \"\$v_script_ask\" are \"yes\" or \"no\"."
fi

v_cur_ocicli=$(${v_oci} -v)

if [ "${v_min_ocicli}" != "`echo -e "${v_min_ocicli}\n${v_cur_ocicli}" | sort -V | head -n1`" ]
then
  exitError "Minimal oci version required is ${v_min_ocicli}. Found: ${v_cur_ocicli}"
fi

v_ocicli_timeout=3600

[ -z "${v_oci_args}" ] || v_oci="${v_oci} ${v_oci_args}"
v_oci_orig="${v_oci}"

#### FUNCTIONS

function getOrigRegion ()
{
  local v_file v_region
  v_file=~/.oci/config
  if $(echo "$v_oci_args" | grep -q -- '--config-file')
  then
    exitError "Please specify Source Region parameter."
  fi
  v_region=$(cat "${v_file}" | grep "region=" | sed 's/region=//')
  [ ! -r "${v_file}" ] && exitError "Could not read OCI config file."
  if [ -n "${v_region}" ]
  then
    echo ${v_region}
  else
    exitError "Could not get Source Region."
  fi
}

function setRetion ()
{
  # Receive region argument and set as oci-cli parameter
  v_oci="$v_oci_orig"
  [ -n "$1" ] && v_oci="${v_oci} --region $1"
  return 0
}

function funcReadVarValidate ()
{
  local v_arg1 v_arg2 v_arg3 v_arg4 v_arg5 v_arg6 v_var1 v_check v_loop
  # 1 to 4 parameters must be provided
  [ "$#" -ge 1 ] || return 2
  v_arg1="$1" # Question
  v_arg2="$2" # Suggestion
  v_arg3="$3" # Options Title
  v_arg4="$4" # Options
  v_arg5="$5" # Error
  v_arg6="$6" # ID / Description Separator
  [ -n "${v_arg1}" ] || return 2
  [ -n "${v_arg3}" -a -n "${v_arg4}" ] && echo "${v_arg3}:"
  [ -z "${v_arg4}" ] || funcPrintRange "${v_arg4}"
  v_loop=1
  while [ ${v_loop} -eq 1 ]
  do
    echo -n "${v_arg1}"
    [ -n "${v_arg2}" ] && echo -n " [${v_arg2}]"
    echo -n ": "
    read v_var1
    [ -z "${v_var1}" -a -n "${v_arg2}" ] && v_var1="${v_arg2}"
    v_loop=0
    if [ -n "${v_arg4}" ]
    then
      v_check=$(funcCheckValueInRange "${v_var1}" "${v_arg4}" "${v_arg6}") || true
      if [ -z "${v_check}" -o "${v_check}" == "N" ]
      then
        [ -z "${v_arg5}" ] || echoError "${v_arg5}"
        v_loop=1
      else
        [ -z "${v_arg6}" ] || v_var1=$(echo "${v_var1}" | sed "s/${v_arg6}.*//")
      fi
    fi
    [ -z "${v_var1}" ] && v_loop=1
  done
  v_return="${v_var1}"
  return 0
}

function funcCheckValueInRange ()
{
  local v_arg1 v_arg2 v_arg3 v_list v_opt IFS
  v_arg1="$1" # Value
  v_arg2="$2" # Range
  v_arg3="$3" # ID / Description Separator
  [ "$#" -ge 2 -a "$#" -le 3 ] || return 1
  [ -n "${v_arg1}" ] || return 1
  [ -n "${v_arg2}" ] || return 1
  v_list=$(echo "${v_arg2}" | tr "," "\n")
  IFS=$'\n'
  for v_opt in ${v_list}
  do
    [ -z "${v_arg3}" ] || v_opt=$(echo "${v_opt}" | sed "s/${v_arg3}.*//")
    if [ "$v_opt" == "${v_arg1}" ]
    then
      echo "Y"
      return 0
    fi
  done
  echo "N"
  return 1
}

function funcPrintRange ()
{
  local v_arg1 v_list v_opt IFS
  v_arg1="$1" # Range
  [ "$#" -eq 1 ] || return 1
  [ -n "${v_arg1}" ] || return 1
  v_list=$(echo "${v_arg1}" | tr "," "\n")
  IFS=$'\n'
  for v_opt in ${v_list}
  do
    echo "- ${v_opt}"
  done
}

function in_subnet ()
{
  # Doug R. in https://unix.stackexchange.com/questions/274330/check-ip-is-in-range-of-whitelist-array
  # Determine whether IP address is in the specified subnet.
  #
  # Args:
  #   sub: Subnet, in CIDR notation.
  #   ip: IP address to check.
  #
  # Returns:
  #   1|0
  #
  local ip ip_a mask netmask sub sub_ip rval start end
  
  # Define bitmask.
  local readonly BITMASK=0xFFFFFFFF
  
  # Set DEBUG status if not already defined in the script.
  [[ "${DEBUG}" == "" ]] && DEBUG=0
  
  # Read arguments.
  IFS=/ read sub mask <<< "${1}"
  IFS=. read -a sub_ip <<< "${sub}"
  IFS=. read -a ip_a <<< "${2}"
  
  # Calculate netmask.
  netmask=$(($BITMASK<<$((32-$mask)) & $BITMASK))
  
  # Determine address range.
  start=0
  for o in "${sub_ip[@]}"
  do
    start=$(($start<<8 | $o))
  done
  
  start=$(($start & $netmask))
  end=$(($start | ~$netmask & $BITMASK))
  
  # Convert IP address to 32-bit number.
  ip=0
  for o in "${ip_a[@]}"
  do
    ip=$(($ip<<8 | $o))
  done
  
  # Removing Network, Gateway and Broadcast:
  ((start+=2))
  ((end-=1))
  
  # Determine if IP in range.
  (( $ip >= $start )) && (( $ip <= $end )) && rval=1 || rval=0
  
  (( $DEBUG )) && printf "ip=0x%08X; start=0x%08X; end=0x%08X; in_subnet=%u\n" $ip $start $end $rval 1>&2
  
  echo "${rval}"
}

function lineToComma ()
{
  echo "${1}" | sort | tr "\n" "," | sed 's/,$//'
}

#### BEGIN

[ -z "${v_orig_region}" ] && v_orig_region=$(getOrigRegion)
setRetion "${v_orig_region}"

#### Validade OCI-CLI and PARAMETER

v_all_compJson=$(${v_oci} iam compartment list --all 2>&1) && v_ret=$? || v_ret=$?
if [ $v_ret -ne 0 ]
then
  echoError "oci-cli not able to run \"${v_oci} iam compartment list --all\". Please check error:"
  exitError "$v_all_compJson"
fi
v_all_compJson=$(echo ${v_all_compJson} | ${v_jq} -rc '.data[] | select(."lifecycle-state" != "DELETED")')
checkError "$v_all_compJson" "Could not get Json for compartments."

function getInstanceID ()
{
  # Receives a parameter that can be either the Compute OCID or Display Name. Returns the Intance OCID and Display Name.
  # If Display Name is duplicated on the region, returns an error.
  local v_instID v_instName v_comp v_list_comps v_ret v_out
  v_instName="$1"
  if [ "${v_instName:0:18}" == "ocid1.instance.oc1" ]
  then
    v_instID=$(${v_oci} compute instance get --instance-id "${v_instName}" | ${v_jq} -rc '.data | select(."lifecycle-state" != "TERMINATED") | ."id"') && v_ret=$? || v_ret=$?
    checkError "$v_instID" "$v_ret" "Could not find a compute with the provided OCID."
    v_instName=$(${v_oci} compute instance get --instance-id "${v_instID}" | ${v_jq} -rc '.data."display-name"') && v_ret=$? || v_ret=$?
    checkError "$v_instName" "$v_ret" "Could not get Display Name of compute ${v_instID}"
  else
    v_list_comps=$(echo ${v_all_compJson} | ${v_jq} -rc '."id"') && v_ret=$? || v_ret=$?
    checkError "$v_list_comps" "$v_ret" "Could not list Compartments."
    for v_comp in $v_list_comps
    do
      v_out=$(${v_oci} compute instance list --compartment-id "$v_comp" --all | ${v_jq} -rc '.data[] | select(."display-name" == "'"${v_instName}"'" and ."lifecycle-state" != "TERMINATED") | ."id"') && v_ret=$? || v_ret=$?
      checkError "x" "$v_ret" "Could not search the OCID of compute ${v_instName} in compartment ${v_comp}. Use OCID instead."
      if [ -n "$v_out" ]
      then
        [ -z "$v_instID" ] || exitError "More than 1 compute named \"${v_instName}\" found in this Tenancy. Use OCID instead."
        [ -n "$v_instID" ] || v_instID="$v_out"
      fi
    done
    if [ -z "$v_instID" ]
    then
      exitError "Could not get OCID of compute ${v_instName}"
    elif [ $(echo "$v_instID" | wc -l) -ne 1 ]
    then
      exitError "More than 1 compute named \"${v_instName}\" found in one Compartment. Use OCID instead."
    fi
  fi
  echo "${v_instID}|${v_instName}"
}

echo "Checking Compute Name and OCID."
v_out=$(getInstanceID "${v_orig_instName}")
read v_orig_instID v_orig_instName <<< $(echo "${v_out}" | awk -F'|' '{print $1, $2}')
echoStatus "Compute Name: ${v_orig_instName}"
echoStatus "Compute OCID: ${v_orig_instID}"

#### Collect Origin Information

echo "Getting OCI Compute information.."

v_orig_instJson=$(${v_oci} compute instance get --instance-id "${v_orig_instID}" | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
checkError "$v_orig_instJson" "$v_ret" "Could not get Json for compute ${v_orig_instName}"

v_orig_compID=$(echo "$v_orig_instJson" | ${v_jq} -rc '."compartment-id"')
checkError "$v_orig_compID" "Could not get Instance Compartment ID."
v_orig_compArg="--compartment-id ${v_orig_compID}"

v_orig_vnicsJson=$(${v_oci} compute instance list-vnics --all --instance-id "${v_orig_instID}" | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
checkError "$v_orig_vnicsJson" "$v_ret" "Could not get Json for vnics of ${v_orig_instName}"

v_orig_vnicPriJson=$(echo "$v_orig_vnicsJson" | ${v_jq} -rc 'select (."is-primary" == true)')
v_orig_vnicSecJson=$(echo "$v_orig_vnicsJson" | ${v_jq} -rc 'select (."is-primary" != true)')

v_orig_pubIPJson=$(${v_oci} network public-ip list ${v_orig_compArg} --scope REGION --all | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
checkError "$v_orig_pubIPJson" "$v_ret" "Could not get Json for Public IPs of ${v_orig_instName}"
v_orig_pubIPs=$(echo "$v_orig_pubIPJson" | ${v_jq} -rc '."ip-address"')

v_orig_AD=$(echo "$v_orig_instJson" | ${v_jq} -rc '."availability-domain"')
checkError "$v_orig_AD" "Could not get Instance Availability Domain."

v_orig_shape=$(echo "$v_orig_instJson" | ${v_jq} -rc '."shape"')
checkError "$v_orig_shape" "Could not get Instance Shape."

v_orig_IP=$(echo "$v_orig_vnicPriJson" | ${v_jq} -rc '."private-ip"')
checkError "$v_orig_IP" "Could not get Instance Primary Private IP Address."

v_orig_subnetID=$(echo "$v_orig_vnicPriJson" | ${v_jq} -rc '."subnet-id"')
checkError "$v_orig_subnetID" "Could not get Instance Primary Subnet ID."

v_orig_subnetName=$(${v_oci} network subnet get --subnet-id "${v_orig_subnetID}" | ${v_jq} -rc '.data."display-name"')
checkError "$v_orig_subnetName" "Could not get Instance Primary Subnet Name."

v_orig_BVID=$(${v_oci} compute boot-volume-attachment list ${v_orig_compArg} --availability-domain "${v_orig_AD}" --instance-id "${v_orig_instID}" | ${v_jq} -rc '.data[] | ."boot-volume-id"')
checkError "$v_orig_BVID" "Could not get Instance Boot Volume ID."

v_orig_attachVolsJson=$(${v_oci} compute volume-attachment list ${v_orig_compArg} --all --instance-id "${v_orig_instID}") && v_ret=$? || v_ret=$?
checkError "x" "$v_ret" "Could not get Json for Attached Volumes of ${v_orig_instName}"

v_orig_imageID=$(echo "$v_orig_instJson" | ${v_jq} -rc '."image-id"')
checkError "$v_orig_imageID" "Could not get Instance Image ID."

v_orig_imageJson=$(${v_oci} compute image get --image-id ${v_orig_imageID}) && v_ret=$? || v_ret=$?
checkError "$v_orig_imageJson" "$v_ret" "Could not get Image Json."

v_orig_OS=$(echo "$v_orig_imageJson" | ${v_jq} -rc '.data."operating-system"')
checkError "$v_orig_OS" "Could not get Image OS."
[ "${v_orig_OS}" == "Windows" ] && exitError "Cloning Oracle Windows based compute instances is not yet supported by OCI."

#### Collect Clone Information

if [ -z "${v_clone_subnetID}" ]
then
  echo "The Source machine will be temporarily cloned within the same region, so an image can be created without stopping it."
  funcReadVarValidate "Create temporary Clone Compute machine in same subnet as the source" "YES" "Options" "YES,NO" "Invalid Option."
  if [ "${v_return}" == "YES" ]
  then
    v_clone_subnetID="${v_orig_subnetID}"
    v_clone_compArg="${v_orig_compArg}"
  else
    ## Compartment
    v_comps_list=$(echo "${v_all_compJson}" | ${v_jq} -rc '."name"')
    v_orig_compName=$(echo "${v_all_compJson}" | ${v_jq} -rc 'select(."id" == "'${v_orig_compID}'") | ."name"')
    funcReadVarValidate "Choose the container where the temporary Clone Compute will be placed" "${v_orig_compName}" "Available Containers" "$(lineToComma "${v_comps_list}")" "Invalid Container."
    v_clone_compName="${v_return}"
    v_clone_compID=$(echo "${v_all_compJson}" | ${v_jq} -rc 'select(."name" == "'"${v_clone_compName}"'") | ."id"')
    v_clone_compArg="--compartment-id ${v_clone_compID}"
    ## VCN
    v_all_vcnJson=$(${v_oci} network vcn list --all ${v_clone_compArg} | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
    checkError "$v_all_vcnJson" "$v_ret" "Could not get Json for VCNs."
    if [ "${v_orig_compName}" == "${v_clone_compName}" ]
    then
      v_orig_VCNID=$(${v_oci} network subnet get --subnet-id $v_orig_subnetID | ${v_jq} -rc '.data."vcn-id"')
      v_orig_VCNName=$(echo "${v_all_vcnJson}" | ${v_jq} -rc 'select(."id" == "'${v_orig_VCNID}'") | ."display-name"')
    else
      v_orig_VCNName=""
    fi
    v_vcns_list=$(echo "${v_all_vcnJson}" | ${v_jq} -rc '."display-name" + " - " + ."cidr-block"')
    funcReadVarValidate "Choose a clone VCN" "${v_orig_VCNName}" "Available VCNs" "$(lineToComma "${v_vcns_list}")" "Invalid VCN." ' - '
    v_clone_VCNName="${v_return}"
    v_clone_VCNID=$(echo "${v_all_vcnJson}" | ${v_jq} -rc 'select(."display-name" == "'"${v_clone_VCNName}"'") | ."id"')
    ## SubNet
    v_all_subnetJson=$(${v_oci} network subnet list --all ${v_clone_compArg} --vcn-id ${v_clone_VCNID} | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
    checkError "$v_all_subnetJson" "$v_ret" "Could not get Json for Subnets."
    if [ "${v_orig_compName}" == "${v_clone_compName}" -a "${v_orig_VCNName}" == "${v_clone_VCNName}" ]
    then
      v_orig_subnetName=$(echo "${v_all_subnetJson}" | ${v_jq} -rc 'select(."id" == "'${v_orig_subnetID}'") | ."display-name"')
    else
      v_orig_subnetName=""
    fi
    v_subnets_list=$(echo "${v_all_subnetJson}" | ${v_jq} -rc '."display-name" + " - " + ."cidr-block"')
    funcReadVarValidate "Choose a clone Subnet" "${v_orig_subnetName}" "Available Subnets" "$(lineToComma "${v_subnets_list}")" "Invalid Subnet." ' - '
    v_clone_subnetName="${v_return}"
    v_clone_subnetID=$(echo "${v_all_subnetJson}" | ${v_jq} -rc 'select(."display-name" == "'"${v_clone_subnetName}"'") | ."id"')
    echoStatus "Clone Subnet ID: ${v_clone_subnetID}"
  fi
fi

v_clone_subnetJson=$(${v_oci} network subnet get --subnet-id ${v_clone_subnetID} | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
checkError "$v_clone_subnetJson" "$v_ret" "Can't find Clone Subnet."

v_clone_AD=$(echo "${v_clone_subnetJson}" |  ${v_jq} -rc '."availability-domain"')
checkError "${v_clone_AD}" "${v_ret}" "Can't find Clone AD."

v_clone_compID=$(echo "${v_clone_subnetJson}" |  ${v_jq} -rc '."compartment-id"') && v_ret=$? || v_ret=$?
checkError "${v_clone_compID}" "${v_ret}" "Could not get the clone Compartment ID."
v_clone_compArg="--compartment-id ${v_clone_compID}"


#### Collect Target Information

if [ -z "${v_target_instName}" ]
then
  funcReadVarValidate "Target Instance Name" "$(echo "${v_orig_instName}" | sed "${v_sedrep_rule_target_name}")"
  v_target_instName="${v_return}"
fi

[ -n "${v_sedrep_rule_target_name}" ] || v_sedrep_rule_target_name="s|${v_orig_instName}|${v_target_instName}|g"

if [ -z "${v_target_region}" ]
then
  v_all_regionJson=$(${v_oci} iam region-subscription list | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
  checkError "$v_all_regionJson" "$v_ret" "Could not get Json for regions."
  v_regions_list=$(echo "${v_all_regionJson}" | ${v_jq} -rc '."region-name"')
  [ -n "${v_orig_region}" ] && v_regions_list=$(echo "${v_regions_list}" | grep -v "${v_orig_region}")
  funcReadVarValidate "Choose a target region" '' "Available Regions" "$(lineToComma "${v_regions_list}")" "Invalid Region."
  v_target_region="${v_return}"
fi

[ "${v_orig_region}" == "${v_target_region}" ] && exitError "Source and Target regions can't be the same."

setRetion "${v_target_region}"

if [ -z "${v_target_subnetID}" ]
then
  ## Compartment
  v_comps_list=$(echo "${v_all_compJson}" | ${v_jq} -rc '."name"')
  v_orig_compName=$(echo "${v_all_compJson}" | ${v_jq} -rc 'select(."id" == "'${v_orig_compID}'") | ."name"')
  funcReadVarValidate "Choose a target container" "${v_orig_compName}" "Available Containers" "$(lineToComma "${v_comps_list}")" "Invalid Container."
  v_target_compName="${v_return}"
  v_target_compID=$(echo "${v_all_compJson}" | ${v_jq} -rc 'select(."name" == "'"${v_target_compName}"'") | ."id"')
  v_target_compArg="--compartment-id ${v_target_compID}"
  ## VCN
  v_all_vcnJson=$(${v_oci} network vcn list --all ${v_target_compArg} | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
  checkError "$v_all_vcnJson" "$v_ret" "Could not get Json for VCNs."
  if [ "${v_orig_compName}" == "${v_target_compName}" ]
  then
    setRetion "${v_orig_region}"
    v_orig_VCNID=$(${v_oci} network subnet get --subnet-id $v_orig_subnetID | ${v_jq} -rc '.data."vcn-id"')
    v_orig_VCNName=$(echo "${v_all_vcnJson}" | ${v_jq} -rc 'select(."id" == "'${v_orig_VCNID}'") | ."display-name"')
    setRetion "${v_target_region}"
  else
    v_orig_VCNName=""
  fi
  v_vcns_list=$(echo "${v_all_vcnJson}" | ${v_jq} -rc '."display-name" + " - " + ."cidr-block"')
  funcReadVarValidate "Choose a target VCN" "${v_orig_VCNName}" "Available VCNs" "$(lineToComma "${v_vcns_list}")" "Invalid VCN." ' - '
  v_target_VCNName="${v_return}"
  v_target_VCNID=$(echo "${v_all_vcnJson}" | ${v_jq} -rc 'select(."display-name" == "'"${v_target_VCNName}"'") | ."id"')
  ## SubNet
  v_all_subnetJson=$(${v_oci} network subnet list --all ${v_target_compArg} --vcn-id ${v_target_VCNID} | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
  checkError "$v_all_subnetJson" "$v_ret" "Could not get Json for Subnets."
  if [ "${v_orig_compName}" == "${v_target_compName}" -a "${v_orig_VCNName}" == "${v_target_VCNName}" ]
  then
    v_orig_subnetName=$(echo "${v_all_subnetJson}" | ${v_jq} -rc 'select(."id" == "'${v_orig_subnetID}'") | ."display-name"')
  else
    v_orig_subnetName=""
  fi
  v_subnets_list=$(echo "${v_all_subnetJson}" | ${v_jq} -rc '."display-name" + " - " + ."cidr-block"')
  funcReadVarValidate "Choose a target Subnet" "${v_orig_subnetName}" "Available Subnets" "$(lineToComma "${v_subnets_list}")" "Invalid Subnet." ' - '
  v_target_subnetName="${v_return}"
  v_target_subnetID=$(echo "${v_all_subnetJson}" | ${v_jq} -rc 'select(."display-name" == "'"${v_target_subnetName}"'") | ."id"')
  echoStatus "Target Subnet ID: ${v_target_subnetID}"
fi

v_target_subnetJson=$(${v_oci} network subnet get --subnet-id ${v_target_subnetID} | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
checkError "${v_target_subnetJson}" "${v_ret}" "Can't find Target Subnet."

v_all_IPs=$(${v_oci} network private-ip list --all --subnet-id ${v_target_subnetID} | ${v_jq} -rc '.data[]."ip-address"')
v_target_CIDR=$(echo "${v_target_subnetJson}" |  ${v_jq} -rc '."cidr-block"')

v_target_compID=$(echo "${v_target_subnetJson}" |  ${v_jq} -rc '."compartment-id"') && v_ret=$? || v_ret=$?
checkError "${v_target_compID}" "${v_ret}" "Could not get the target Compartment ID."
v_target_compArg="--compartment-id ${v_target_compID}"

v_target_AD=$(echo "${v_target_subnetJson}" | ${v_jq} -rc '."availability-domain"') && v_ret=$? || v_ret=$?
checkError "${v_target_AD}" "${v_ret}" "Can't find Target AD."

v_target_allowPub=$(echo "${v_target_subnetJson}" | ${v_jq} -rc '."prohibit-public-ip-on-vnic"') && v_ret=$? || v_ret=$?
checkError "${v_target_allowPub}" "${v_ret}" "Can't get target IP allowance."

if [ -z "${v_target_IP}" ]
then
  if [ -n "${v_all_IPs}" ]
  then
    echo "Following IP's are already in use:"
    funcPrintRange "$(echo "${v_all_IPs}" | tr "\n" "," | sed 's/,$//')"
  fi
  v_loop=1
  while [ ${v_loop} -eq 1 ]
  do
    v_return=""
    funcReadVarValidate "Choose an IP in \"${v_target_CIDR}\""
    v_check=$(funcCheckValueInRange "${v_return}" "$(lineToComma "${v_all_IPs}")") || true
    if [ "${v_check}" == "Y" -a -n "${v_all_IPs}" ]
    then
      echoError "IP \"$v_return\" already in use."
    else
      v_loop=0
    fi
    (( $(in_subnet "${v_target_CIDR}" "${v_return}") )) || echoError "IP \"$v_return\" not in $v_target_CIDR block."
    (( $(in_subnet "${v_target_CIDR}" "${v_return}") )) || v_loop=1
  done
  v_target_IP="${v_return}"
else
  v_check=$(funcCheckValueInRange "${v_target_IP}" "$(echo "${v_all_IPs}" | tr "\n" "," | sed 's/,$//')") || true
  if [ "${v_check}" == "Y" -a -n "${v_all_IPs}" ]
  then
    exitError "IP \"${v_target_IP}\" already in use."
  fi
  (( $(in_subnet "${v_target_CIDR}" "${v_target_IP}") )) || exitError "IP \"${v_target_IP}\" not in $v_target_CIDR block."
fi

v_all_shapes=$(${v_oci} compute shape list ${v_target_compArg} --all | jq -r '.data[].shape' | sort -u)

if [ -z "${v_target_shape}" ]
then
  echo "Source Instance Shape: ${v_orig_shape}"
  funcReadVarValidate "Target Instance Shape" "${v_orig_shape}" "Available Shapes" "$(lineToComma "${v_all_shapes}")" "Invalid Shape."
  v_target_shape="${v_return}"
else
  v_check=$(funcCheckValueInRange "${v_target_shape}" "$(echo "${v_all_shapes}" | tr "\n" "," | sed 's/,$//')") || true
  if [ -z "${v_check}" -o "${v_check}" == "N" ]
  then
    exitError "Shape does not exist or not available."
  fi
fi

#### Collect Bucket Information

setRetion "${v_orig_region}"

if [ -z "${v_os_bucketName}" ]
then
  ## Compartment
  v_comps_list=$(echo "${v_all_compJson}" | ${v_jq} -rc '."name"')
  v_clone_compName=$(echo "${v_all_compJson}" | ${v_jq} -rc 'select(."id" == "'${v_clone_compID}'") | ."name"')
  funcReadVarValidate "Choose the container where the OS bucket used for migration is placed" "${v_clone_compName}" "Available Containers" "$(lineToComma "${v_comps_list}")" "Invalid Container."
  v_os_compName="${v_return}"
  v_os_compID=$(echo "${v_all_compJson}" | ${v_jq} -rc 'select(."name" == "'"${v_os_compName}"'") | ."id"')
  v_os_compArg="--compartment-id ${v_os_compID}"
  ## VCN
  v_all_bucketJson=$(${v_oci} os bucket list --all ${v_os_compArg} | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
  checkError "$v_all_bucketJson" "$v_ret" "Could not get Json for Buckets."
  v_buckets_list=$(echo "${v_all_bucketJson}" | ${v_jq} -rc '."name"')
  funcReadVarValidate "Choose a bucket for image migration" "" "Available Buckets" "$(lineToComma "${v_buckets_list}")" "Invalid Bucket."
  v_os_bucketName="${v_return}"
fi

v_os_bucketJson=$(${v_oci} os bucket get --bucket-name ${v_os_bucketName} | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
checkError "${v_os_bucketJson}" "${v_ret}" "Can't find OS Bucket."

v_os_bucketPublic=$(echo "${v_os_bucketJson}" | ${v_jq} -rc '."public-access-type"')
checkError "${v_os_bucketPublic}" "Can't get Bucket public attribute."
[ "${v_os_bucketPublic}" == "NoPublicAccess" ] && exitError "OS Bucket must have Public ObjectRead Access enabled."


#####
#####
#####

export v_step=1
function printStep ()
{
  echoStatus "Executing Step $v_step"
  ((v_step++))
}

echo "$v_all_steps"

######
### 01
######

printStep

setRetion "${v_orig_region}"

v_orig_VGName="${v_orig_instName}_VG"

v_volList='{'
v_volList+='"type":"volumeIds",'
v_volList+='"volumeIds": ['
v_volList+='"'${v_orig_BVID}'"'

# Not using "raw" as jq param to include quotes.
v_instvolsID_list=$(echo "$v_orig_attachVolsJson" | ${v_jq} -c '.data[] | select(."lifecycle-state" == "ATTACHED") | ."volume-id"')
for v_instvolsID in $v_instvolsID_list
do
  v_volList+=",${v_instvolsID}"
done

v_volList+=']'
v_volList+='}'

v_params=()
v_params+=(${v_orig_compArg})
v_params+=(--availability-domain ${v_orig_AD})
v_params+=(--display-name "${v_orig_VGName}")
v_params+=(--max-wait-seconds $v_ocicli_timeout)
v_params+=(--wait-for-state AVAILABLE)
v_params+=(--source-details "${v_volList}")

v_orig_VGJson=$(${v_oci} bv volume-group create "${v_params[@]}") && v_ret=$? || v_ret=$?
checkError "$v_orig_VGJson" "$v_ret" "Could not create Volume Group."

v_orig_VGID=$(echo "$v_orig_VGJson"| ${v_jq} -rc '.data."id"')
checkError "$v_orig_VGID" "Could not get Volume ID."

######
### 02
######

printStep

v_orig_VGBackupName="${v_orig_instName}_VG_BKP"

v_params=()
v_params+=(${v_clone_compArg})
v_params+=(--volume-group-id ${v_orig_VGID})
v_params+=(--display-name "${v_orig_VGBackupName}")
v_params+=(--type INCREMENTAL)
v_params+=(--wait-for-state AVAILABLE)
v_params+=(--max-wait-seconds $v_ocicli_timeout)

v_orig_VGBackupJson=$(${v_oci} bv volume-group-backup create "${v_params[@]}") && v_ret=$? || v_ret=$?
checkError "$v_orig_VGBackupJson" "$v_ret" "Could not create Volume Group Backup."

v_orig_VGBackupID=$(echo "$v_orig_VGBackupJson"| ${v_jq} -rc '.data."id"')
checkError "$v_orig_VGBackupID" "Could not get Volume Group Backup ID."

######
### 03
######

printStep

v_params=()
v_params+=(--volume-group-id ${v_orig_VGID})
v_params+=(--force)
v_params+=(--wait-for-state TERMINATED)
v_params+=(--max-wait-seconds $v_ocicli_timeout)

${v_oci} bv volume-group delete "${v_params[@]}" && v_ret=$? || v_ret=$?
checkError "x" "$v_ret" "Could not remove Volume Group."

######
### 04
######

printStep

v_volBkpID_list=$(echo "$v_orig_VGBackupJson" | ${v_jq} -rc '.data."volume-backup-ids"[]')
for v_volBkpID in $v_volBkpID_list
do
  if [ "${v_volBkpID:0:26}" == "ocid1.bootvolumebackup.oc1" ]
  then
    v_clone_BVBackupID="${v_volBkpID}"
  fi
done

v_clone_BVName="${v_orig_instName}_CLONE_BV"

v_params=()
v_params+=(--boot-volume-backup-id ${v_clone_BVBackupID})
v_params+=(--display-name "${v_clone_BVName}")
v_params+=(--availability-domain ${v_clone_AD})
v_params+=(--wait-for-state AVAILABLE)
v_params+=(--max-wait-seconds $v_ocicli_timeout)

v_clone_BVJson=$(${v_oci} bv boot-volume create "${v_params[@]}") && v_ret=$? || v_ret=$?
checkError "$v_clone_BVJson" "$v_ret" "Could not create Boot Volume from Backup."

v_clone_BVID=$(echo "$v_clone_BVJson" | ${v_jq} -rc '.data."id"')
checkError "$v_clone_BVID" "Could not get Boot Volume ID."

######
### 05
######

printStep

v_clone_instName="${v_orig_instName}_CLONE_INST"
v_clone_instShape="VM.Standard2.1"

v_params=()
v_params+=(${v_clone_compArg})
v_params+=(--availability-domain ${v_clone_AD})
v_params+=(--shape ${v_clone_instShape})
v_params+=(--wait-for-state RUNNING)
v_params+=(--max-wait-seconds $v_ocicli_timeout)
v_params+=(--display-name "${v_clone_instName}")
v_params+=(--source-boot-volume-id ${v_clone_BVID})
v_params+=(--subnet-id ${v_clone_subnetID})
v_params+=(--assign-public-ip false)

v_clone_instJson=$(${v_oci} compute instance launch "${v_params[@]}") && v_ret=$? || v_ret=$?
checkError "$v_clone_instJson" "$v_ret" "Could not create Clone Instance."

v_clone_instID=$(echo "$v_clone_instJson" | ${v_jq} -rc '.data."id"')
checkError "$v_clone_instID" "Could not get Clone Instance ID."

######
### 06
######

printStep

v_params=()
v_params+=(--instance-id ${v_clone_instID})
v_params+=(--action STOP)
v_params+=(--wait-for-state STOPPED)
v_params+=(--max-wait-seconds $v_ocicli_timeout)

${v_oci} compute instance action "${v_params[@]}" >&- && v_ret=$? || v_ret=$?
checkError "x" "$v_ret" "Could not stop Clone Instance."

######
### 07
######

printStep

v_clone_imageName="${v_orig_instName}_IMAGE"

v_params=()
v_params+=(${v_clone_compArg})
v_params+=(--display-name "${v_clone_imageName}")
v_params+=(--instance-id ${v_clone_instID})
v_params+=(--wait-for-state AVAILABLE)
v_params+=(--max-wait-seconds $v_ocicli_timeout)

v_clone_imageJson=$(${v_oci} compute image create "${v_params[@]}") && v_ret=$? || v_ret=$?
checkError "$v_clone_imageJson" "$v_ret" "Could not create Image from Clone Instance."

v_clone_imageID=$(echo "$v_clone_imageJson" | ${v_jq} -rc '.data."id"')
checkError "$v_clone_imageID" "Could not get Clone Instance Image ID."

######
### 08
######

printStep

v_params=()
v_params+=(--instance-id ${v_clone_instID})
v_params+=(--preserve-boot-volume false)
v_params+=(--force)
v_params+=(--wait-for-state TERMINATED)
v_params+=(--max-wait-seconds $v_ocicli_timeout)

${v_oci} compute instance terminate "${v_params[@]}" && v_ret=$? || v_ret=$?
checkError "x" "$v_ret" "Could not terminate Clone Instance."

######
### 09
######

"${v_workdir}"/${v_oci_image_clone_script} "${v_clone_imageID}" "${v_os_bucketName}" "${v_target_region}" "${v_orig_region}"

setRetion "${v_target_region}"

v_params=()
v_params+=(${v_clone_compArg})

v_target_imageJson=$(${v_oci} compute image list "${v_params[@]}" | ${v_jq} -rc '.data[] | select (."freeform-tags"."Source_OCID"=="'${v_clone_imageID}'")') && v_ret=$? || v_ret=$?
checkError "$v_target_imageJson" "$v_ret" "Could not get Json of imported Image."

v_target_imageID=$(echo "$v_target_imageJson" | ${v_jq} -rc '."id"')
checkError "$v_target_imageID" "Could not get OCID of imported Image."

######
### 14
######

v_step=$((v_step+5))

printStep

setRetion "${v_orig_region}"

v_params=()
v_params+=(--image-id ${v_clone_imageID})
v_params+=(--force)
v_params+=(--wait-for-state DELETED)
v_params+=(--max-wait-seconds $v_ocicli_timeout)

${v_oci} compute image delete "${v_params[@]}" && v_ret=$? || v_ret=$?
checkError "x" "$v_ret" "Could not delete Source Image."

######
### 15
######

printStep

setRetion "${v_target_region}"

v_params=()
# --skip-source-dest-check
v_out=$(echo "$v_orig_vnicPriJson" | ${v_jq} -rc '."skip-source-dest-check"')
[ -z "$v_out" ] || v_params+=(--skip-source-dest-check "$v_out")
# --assign-public-ip
v_out=$(echo "$v_orig_vnicPriJson" | ${v_jq} -rc '."public-ip" // empty')
if [ -n "$v_out" -a "${v_target_allowPub}" == "false" ]
then
  if grep -q -F -x "$v_out" <(echo "$v_orig_pubIPs")
  then
    v_params+=(--assign-public-ip false)
  else
    v_params+=(--assign-public-ip true)
  fi
else
  v_params+=(--assign-public-ip false)
fi
# --defined-tags
v_out=$(echo "$v_orig_instJson" | ${v_jq} -rc '."defined-tags"')
[ -z "$v_out" -o "$v_out" == "{}" ] || v_params+=(--defined-tags "$v_out")
# --freeform-tags
v_out=$(echo "$v_orig_instJson" | ${v_jq} -rc '."freeform-tags"')
[ -z "$v_out" -o "$v_out" == "{}" ] || v_params+=(--freeform-tags "$v_out")
# --metadata
v_out=$(echo "$v_orig_instJson" | ${v_jq} -rc '."metadata"')
[ -z "$v_out" -o "$v_out" == "{}" ] || v_params+=(--metadata "$v_out")
# --extended-metadata
v_out=$(echo "$v_orig_instJson" | ${v_jq} -rc '."extended-metadata"')
[ -z "$v_out" -o "$v_out" == "{}" ] || v_params+=(--extended-metadata "$v_out")
# --fault-domain
v_out=$(echo "$v_orig_instJson" | ${v_jq} -rc '."fault-domain"')
[ -z "$v_out" ] || v_params+=(--fault-domain "$v_out")
# --ipxe-script-file
v_out=$(echo "$v_orig_instJson" | ${v_jq} -rc '."ipxe-script" // empty')
[ -z "$v_out" ] || v_params+=(--ipxe-script-file "$v_out")

v_params+=(--availability-domain ${v_target_AD})
v_params+=(--shape "${v_target_shape}")
v_params+=(--wait-for-state RUNNING)
v_params+=(--max-wait-seconds $v_ocicli_timeout)
v_params+=(--display-name "${v_target_instName}")
v_params+=(--image-id ${v_target_imageID})
v_params+=(--subnet-id ${v_target_subnetID})
v_params+=(--private-ip ${v_target_IP})
v_params+=(${v_target_compArg})

v_target_instJson=$(${v_oci} compute instance launch "${v_params[@]}") && v_ret=$? || v_ret=$?
checkError "$v_target_instJson" "$v_ret" "Could not create Target Instance."

v_target_instID=$(echo "$v_target_instJson" | ${v_jq} -rc '.data."id"')
checkError "$v_target_instID" "Could not get Target Instance ID."

######
### 16
######

printStep

v_params=()
v_params+=(--image-id ${v_target_imageID})
v_params+=(--force)
v_params+=(--wait-for-state DELETED)
v_params+=(--max-wait-seconds $v_ocicli_timeout)
${v_oci} compute image delete "${v_params[@]}" && v_ret=$? || v_ret=$?
checkError "x" "$v_ret" "Could not delete Target Image."

######
### 17
######

printStep

v_target_volBackupList=()
v_orig_VGBackupVolList=$(echo "$v_orig_VGBackupJson" | ${v_jq} -rc '.data."volume-backup-ids"[]')
for v_orig_VGBackupVolID in $v_orig_VGBackupVolList
do
  if [ "${v_orig_VGBackupVolID:0:22}" == "ocid1.volumebackup.oc1" ]
  then

    v_params=()
    v_params+=(--volume-backup-id ${v_orig_VGBackupVolID})
    v_params+=(--destination-region "${v_target_region}")

    setRetion "${v_target_region}"

    ## Check if there is any copy currently going on..
    while true
    do
      v_target_volBackupJson=$(${v_oci} bv backup list ${v_target_compArg} --all) && v_ret=$? || v_ret=$?
      checkError "$v_target_volBackupJson" "$v_ret" "Could not get Target Backup status."
      v_target_bkpVolStatus=$(echo "$v_target_volBackupJson" | ${v_jq} -rc '.data[] | select(."lifecycle-state"=="CREATING" and ."source-volume-backup-id"!=null) | ."lifecycle-state"' | sort -u)
      [ -z "${v_target_bkpVolStatus}" ] && break
      echo "There are backups with status ${v_target_bkpVolStatus} in target. Please wait."
      sleep 180
    done

    setRetion "${v_orig_region}"

    v_target_volBackupJson=$(${v_oci} bv backup copy "${v_params[@]}") && v_ret=$? || v_ret=$?
    checkError "$v_target_volBackupJson" "$v_ret" "Could not copy the backup to target region."

    v_target_volBackupID=$(echo "$v_target_volBackupJson" | ${v_jq} -rc '.data."id"')
    
    setRetion "${v_target_region}"

    while true
    do
      v_target_volBackupJson=$(${v_oci} bv backup get --volume-backup-id ${v_target_volBackupID}) && v_ret=$? || v_ret=$?
      checkError "$v_target_volBackupJson" "$v_ret" "Could not get Backup status."
      v_target_bkpVolStatus=$(echo "$v_target_volBackupJson" | ${v_jq} -rc '.data."lifecycle-state"')
      [ "${v_target_bkpVolStatus}" != "AVAILABLE" ] || break
      echo "Backup status is ${v_target_bkpVolStatus}. Please wait."
      sleep 180
    done

    v_target_volBackupList+=(${v_target_volBackupID})
  fi
done

######
### 18
######

printStep

setRetion "${v_orig_region}"

v_params=()
v_params+=(--volume-group-backup-id ${v_orig_VGBackupID})
v_params+=(--force)
v_params+=(--wait-for-state TERMINATED)
v_params+=(--max-wait-seconds $v_ocicli_timeout)
${v_oci} bv volume-group-backup delete "${v_params[@]}" && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 ] || echoError "Could not remove Volume Group Backup."

######
### 19
######

printStep

v_orig_volList=()
v_target_volList=()
for v_target_volBackupID in "${v_target_volBackupList[@]}"
do
  setRetion "${v_target_region}"

  v_target_volBackupJson=$(${v_oci} bv backup get --volume-backup-id ${v_target_volBackupID}) && v_ret=$? || v_ret=$?
  checkError "$v_target_volBackupJson" "$v_ret" "Could not get Backup Json."
  v_orig_volBackupID=$(echo "$v_target_volBackupJson" | ${v_jq} -rc '.data."source-volume-backup-id"')

  setRetion "${v_orig_region}"

  v_orig_volID=$(${v_oci} bv backup get --volume-backup-id ${v_orig_volBackupID} | ${v_jq} -rc '.data."volume-id"') && v_ret=$? || v_ret=$?
  checkError "$v_orig_volID" "$v_ret" "Could not get Volume ID."
  v_orig_volJson=$(${v_oci} bv volume get --volume-id ${v_orig_volID} | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
  checkError "$v_orig_volJson" "$v_ret" "Could not get Volume json."
  v_orig_volName=$(echo "${v_orig_volJson}" | ${v_jq} -rc '."display-name"')
  v_target_volName=$(echo "${v_orig_volName}" | sed "${v_sedrep_rule_target_name}")

  v_origVolBkpPolID=$(${v_oci} bv volume-backup-policy-assignment get-volume-backup-policy-asset-assignment --asset-id ${v_orig_volID} | ${v_jq} -rc '.data[]."policy-id"') && v_ret=$? || v_ret=$?
  checkError "x" "$v_ret" "Could not get Volume Backup Policy ID." # Can be null

  setRetion "${v_target_region}"

  v_params=()
  v_params+=(${v_target_compArg})
  v_params+=(--display-name "${v_target_volName}")
  v_params+=(--availability-domain ${v_target_AD})
  v_params+=(--volume-backup-id ${v_target_volBackupID})
  v_params+=(--wait-for-state AVAILABLE)
  v_params+=(--max-wait-seconds $v_ocicli_timeout)
  [ -z "${v_origVolBkpPolID}" ] || v_params+=(--backup-policy-id ${v_origVolBkpPolID})
  # --defined-tags
  v_out=$(echo "$v_orig_volJson" | ${v_jq} -rc '."defined-tags"')
  [ -z "$v_out" -o "$v_out" == "{}" ] || v_params+=(--defined-tags "$v_out")
  # --freeform-tags
  v_out=$(echo "$v_orig_volJson" | ${v_jq} -rc '."freeform-tags"')
  [ -z "$v_out" -o "$v_out" == "{}" ] || v_params+=(--freeform-tags "$v_out")
  #v_params+=(--size-in-gbs)
  #v_params+=(--size-in-mbs)

  v_target_volJson=$(${v_oci} bv volume create "${v_params[@]}") && v_ret=$? || v_ret=$?
  checkError "$v_target_volJson" "$v_ret" "Could not create Volume."
  v_target_volID=$(echo "$v_target_volJson"| ${v_jq} -rc '.data."id"')
  v_orig_volList+=(${v_orig_volID})
  v_target_volList+=(${v_target_volID})
done

######
### 20
######

setRetion "${v_target_region}"

printStep

for v_target_volBackupID in "${v_target_volBackupList[@]}"
do
  v_params=()
  v_params+=(--volume-backup-id ${v_target_volBackupID})
  v_params+=(--force)
  v_params+=(--wait-for-state TERMINATED)
  v_params+=(--max-wait-seconds $v_ocicli_timeout)

  ${v_oci} bv backup delete "${v_params[@]}" && v_ret=$? || v_ret=$?
  [ $v_ret -eq 0 ] || echoError "Could not remove Target Volume Backup."
done

######
### 21
######

printStep

v_i=0
for v_target_volID in "${v_target_volList[@]}"
do
  v_orig_volID=${v_orig_volList[${v_i}]}

  ####
  v_voltype=$(echo "$v_orig_attachVolsJson" | jq -rc '.data[] | select(."volume-id" == "'${v_orig_volID}'") | ."attachment-type"')
  v_volro=$(echo "$v_orig_attachVolsJson" | jq -rc '.data[] | select(."volume-id" == "'${v_orig_volID}'") | ."is-read-only"')
  ####

  v_params=()
  v_params+=(--instance-id "${v_target_instID}")
  v_params+=(--type "${v_voltype}")
  v_params+=(--volume-id "${v_target_volID}")
  v_params+=(--is-read-only "${v_volro}")
  v_params+=(--wait-for-state ATTACHED)
  v_params+=(--max-wait-seconds $v_ocicli_timeout)

  ${v_oci} compute volume-attachment attach "${v_params[@]}" >&- && v_ret=$? || v_ret=$?
  checkError "x" "$v_ret" "Could not associate target volume."

  ((++v_i)) # ((v_i++)) will abort the script
done

######
### 22
######

printStep

v_skip_ssh=0
if [ "${v_orig_OS}" == "Windows" ]
then
  v_skip_ssh=1
fi

v_iscsiadm=""
for v_orig_volID in "${v_orig_volList[@]}"
do
  v_iqn=$(echo "$v_orig_attachVolsJson" | ${v_jq} -rc '.data[] | select (."volume-id" == "'${v_orig_volID}'") | ."iqn"')
  v_ipv4=$(echo "$v_orig_attachVolsJson" | ${v_jq} -rc '.data[] | select (."volume-id" == "'${v_orig_volID}'") | ."ipv4"')
  v_port=$(echo "$v_orig_attachVolsJson" | ${v_jq} -rc '.data[] | select (."volume-id" == "'${v_orig_volID}'") | ."port"')
  v_iscsiadm+="sudo iscsiadm -m node -T ${v_iqn} -p ${v_ipv4}:${v_port} -u"$'\n'
  v_iscsiadm+="sudo iscsiadm -m node -o delete -T ${v_iqn} -p ${v_ipv4}:${v_port}"$'\n'
done

setRetion "${v_target_region}"

v_target_attachVolsJson=$(${v_oci} compute volume-attachment list ${v_target_compArg} --all --instance-id "${v_target_instID}" | ${v_jq} -r '.data[] | select(."lifecycle-state" == "ATTACHED")')

for v_target_volID in "${v_target_volList[@]}"
do
  v_iqn=$(echo "$v_target_attachVolsJson" | ${v_jq} -rc 'select (."volume-id" == "'${v_target_volID}'") | ."iqn"')
  v_ipv4=$(echo "$v_target_attachVolsJson" | ${v_jq} -rc 'select (."volume-id" == "'${v_target_volID}'") | ."ipv4"')
  v_port=$(echo "$v_target_attachVolsJson" | ${v_jq} -rc 'select (."volume-id" == "'${v_target_volID}'") | ."port"')
  v_iscsiadm+="sudo iscsiadm -m node -o new -T ${v_iqn} -p ${v_ipv4}:${v_port}"$'\n'
  v_iscsiadm+="sudo iscsiadm -m node -o update -T ${v_iqn} -n node.startup -v automatic"$'\n'
  v_iscsiadm+="sudo iscsiadm -m node -T ${v_iqn} -p ${v_ipv4}:${v_port} -l"$'\n'
done

function sshExecute ()
{
  local v_loop v_timeout v_sleep v_total v_input v_ret v_IP v_code
  v_IP="$1"
  v_code="$2"
  echo ""
  echo '## IF YOUR INSTANCE IS LINUX, CONNECT AS OPC AND EXECUTE:'
  echo '## '$(printf '=%.0s' {1..80})
  echo -n "${v_code}"
  echo '## '$(printf '=%.0s' {1..80})
  echo ""

  ## Ask if reconfig using SSH

  if [ "${v_script_ask}" == "yes" ]; then
    echo "Lines above must be executed in target linux machine."
    echo -n "Type \"YES\" to apply the changes via SSH as opc@${v_IP}: "
    read v_input
  else
    v_input="YES"
  fi
  if [ "$v_input" == "YES" ]
  then
    ## Wait SSH UP
    echo 'Checking Server availability..'
    v_loop=1
    v_timeout=5
    v_sleep=10
    v_total=40
    while [ ${v_loop} -le ${v_total} ]
    do
      timeout ${v_timeout} bash -c "true &>/dev/null </dev/tcp/$v_IP/22" && v_ret=$? || v_ret=$?
      [ $v_ret -eq 0 ] && v_loop=$((v_total+1)) && echo 'Server Available!' && sleep 3
      [ $v_ret -ne 0 ] && echo "Server Unreachable, please wait. Try ${v_loop} of ${v_total}." && v_loop=$((v_loop+1)) && sleep ${v_sleep}
    done

    ## Update Attachments
    ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no opc@${v_IP} "bash -s" < <(echo "$v_code")
    echo ""

  fi
}

if [ -n "${v_iscsiadm}" -a ${v_skip_ssh} -eq 0 ]
then

  sshExecute "${v_target_IP}" "${v_iscsiadm}"

  ## Restart Machine
  echo 'Bouncing the instance..'
  v_params=()
  v_params+=(--instance-id "${v_target_instID}")
  v_params+=(--action SOFTRESET)
  v_params+=(--wait-for-state RUNNING)
  v_params+=(--max-wait-seconds $v_ocicli_timeout)
  ${v_oci} compute instance action "${v_params[@]}" >&- && v_ret=$? || v_ret=$?
  checkError "x" "$v_ret" "Not able to bounce the instance."

fi

######
######
######

echo "SCRIPT EXECUTED SUCCESSFULLY"
exit 0

## TODO SEC VNICS / PRI VNIC TAGS INFO