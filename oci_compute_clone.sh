#!/bin/bash
#************************************************************************
#
#   oci_compute_clone.sh - Clone a compute instance in same region
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
# Created on: Oct/2018 by Rodrigo Jorge
# Version 1.04
#************************************************************************
set -e

# Define paths for oci-cli and jq or put them on $PATH. Don't use relative PATHs in the variables below.
v_oci="oci"
v_jq="jq"

# Add any desired oci argument. Keep default to avoid oci_cli_rc usage.
[ -n "${OCI_CLI_ARGS}" ] && v_oci_args="${OCI_CLI_ARGS}"
[ -z "${OCI_CLI_ARGS}" ] && v_oci_args="--cli-rc-file /dev/null"

# Don't change it.
v_min_ocicli="2.4.30"

read -r -d '' v_all_steps << EOM || true
## Macro Steps
# 1 - Create Volume Group with instance Boot-Volume and Volumes.
# 2 - Backup Volume Group.
# 3 - Remove Volume Group.
# 4 - Create new Boot-Volume and Volumes from the backup.
# 5 - Remove Backup.
# 6 - Create a new Instance with Boot-Volume.
# 7 - Attach all new Volumes to it.
# 8 - Generate iscsiadm commands.
EOM

####
#### INTERNAL - IF NOT PROVIDED HERE OR AS PARAMETERS, WILL BE ASKED DURING CODE EXECUTION.
####
v_target_instName=""                           # Define if dont want to keep the same as source
v_target_shape=""                              # Define if dont want to keep the same as source
v_target_subnetID=""                           # Define if dont want to keep the same as source
v_target_IP=""                                 # Define if dont want to keep the same as source
v_sedrep_rule_target_name=""                   # Rule to convert objects name. If NULL will be automatically populated.
####

# Helpful functions

function echoError ()
{
   (>&2 echo "$1")
}

function exitError ()
{
   echoError "$1"
   ( set -o posix ; set ) > /tmp/oci_debug.$(date '+%Y%m%d%H%M%S').txt
   exit 1
}

# trap
trap 'exitError "Code Interrupted."' INT SIGINT SIGTERM

v_orig_instName="$1"
[ -n "$2" ] && v_target_instName="$2"
[ -n "$3" ] && v_target_shape="$3"
[ -n "$4" ] && v_target_subnetID="$4"
[ -n "$5" ] && v_target_IP="$5"

# If first parameter starts with '-' or is 'help'
if [ "${v_orig_instName:0:1}" == "-" -o "${v_orig_instName}" == "help" -o "$#" -eq 0 ]
then
  echoError "$0: All parameters, except first, are optional to run this tool."
  echoError "- 1st param = Source Compute Instance Name or OCID"
  echoError "- 2nd param = Target Compute Instance Name"
  echoError "- 3rd param = Target Compute Shape"
  echoError "- 4th param = Target Subnet ID"
  echoError "- 5th param = Target IP Address"
  exit 1
fi

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

v_ocicli_timeout=36000

[ -z "${v_oci_args}" ] || v_oci="${v_oci} ${v_oci_args}"

#### FUNCTIONS

function funcReadVarValidate ()
{
  local v_arg1 v_arg2 v_arg3 v_arg4 v_arg5 v_var1 v_check v_loop
  # 1 to 4 parameters must be provided
  [ "$#" -ge 1 -a "$#" -le 5 ] || return 2
  v_arg1="$1" # Question
  v_arg2="$2" # Suggestion
  v_arg3="$3" # Options
  v_arg4="$4" # Error
  v_arg5="$5" # ID / Description Separator
  [ -n "${v_arg1}" ] || return 2
  [ -z "${v_arg3}" ] || echo "${v_arg1}:"
  [ -z "${v_arg3}" ] || funcPrintRange "${v_arg3}"
  v_loop=1
  while [ ${v_loop} -eq 1 ]
  do
    echo -n "${v_arg1}"
    [ -z "${v_arg2}" ] || echo -n " [${v_arg2}]"
    echo -n ": "
    read v_var1
    [ -n "${v_var1}" -o -z "${v_arg2}" ] || v_var1="${v_arg2}"
    v_loop=0
    if [ -n "${v_arg3}" ]
    then
      v_check=$(funcCheckValueInRange "${v_var1}" "${v_arg3}" "${v_arg5}") || true
      if [ -z "${v_check}" -o "${v_check}" == "N" ]
      then
        [ -z "${v_arg4}" ] || echoError "${v_arg4}"
        v_loop=1
      else
        [ -z "${v_arg5}" ] || v_var1=$(echo "${v_var1}" | sed "s/${v_arg5}.*//")
      fi
    fi
    [ -n "${v_var1}" ] || v_loop=1
  done
  v_return="${v_var1}"
  return 0
}

function funcCheckValueInRange ()
{
  local v_arg1 v_arg2 v_arg3 v_list v_opt IFS
  IFS=$'\n'
  [ "$#" -ge 2 -a "$#" -le 3 ] || return 1
  v_arg1="$1" # Value
  v_arg2="$2" # Range
  v_arg3="$3" # ID / Description Separator
  [ -n "${v_arg1}" ] || return 1
  [ -n "${v_arg2}" ] || return 1
  v_list=$(echo "${v_arg2}" | tr "," "\n")
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
  IFS=$'\n'
  [ "$#" -eq 1 ] || return 1
  v_arg1="$1" # Range
  [ -n "${v_arg1}" ] || return 1
  v_list=$(echo "${v_arg1}" | tr "," "\n")
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

#### BEGIN

#### Validade OCI-CLI and PARAMETER

v_test=$(${v_oci} iam compartment list --all 2>&1) && v_ret=$? || v_ret=$?
if [ $v_ret -ne 0 ]
then
  echoError "oci-cli not able to run \"${v_oci} iam compartment list --all\". Please check error:"
  echoError "$v_test"
  exit 1
fi

#### BEGIN INPUT VALIDATIONS

if [ -z "${v_orig_instName}" ]
then
  funcReadVarValidate "Source Instance Name or OCID"
  v_orig_instName="${v_return}"
fi

if [ "${v_orig_instName:0:18}" == "ocid1.instance.oc1" ]
then
  v_orig_instID=$(${v_oci} compute instance get --instance-id "${v_orig_instName}" | ${v_jq} -rc '.data | select(."lifecycle-state" != "TERMINATED") | ."id"') && v_ret=$? || v_ret=$?
  [ $v_ret -eq 0 -a -n "$v_orig_instID" ] || exitError "Could not find a compute with the provided OCID."
  v_orig_instName=$(${v_oci} compute instance get --instance-id "${v_orig_instID}" | ${v_jq} -rc '.data."display-name"') && v_ret=$? || v_ret=$?
  [ $v_ret -eq 0 -a -n "$v_orig_instName" ] || exitError "Could not get Display Name of compute ${v_orig_instID}"
else
  v_comps_list=$(${v_oci} iam compartment list --all | ${v_jq} -rc '.data[]."id"') && v_ret=$? || v_ret=$?
  [ $v_ret -eq 0 -a -n "$v_comps_list" ] || exitError "Could not list Compartments."
  for v_comp in $v_comps_list
  do
    v_out=$(${v_oci} compute instance list --compartment-id "$v_comp" --all | ${v_jq} -rc '.data[] | select(."display-name" == "'"${v_orig_instName}"'" and ."lifecycle-state" != "TERMINATED") | ."id"') && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 ] || exitError "Could not search the OCID of compute ${v_orig_instName} in compartment ${v_comp}. Use OCID instead."
    if [ -n "$v_out" ]
    then
      [ -z "$v_orig_instID" ] || exitError "More than 1 compute named \"${v_orig_instName}\" found in this Tenancy. Use OCID instead."
      [ -n "$v_orig_instID" ] || v_orig_instID="$v_out"
    fi
  done
  if [ -z "$v_orig_instID" ]
  then
    exitError "Could not get OCID of compute ${v_orig_instName}"
  elif [ $(echo "$v_orig_instID" | wc -l) -ne 1 ]
  then
    exitError "More than 1 compute named \"${v_orig_instName}\" found in one Compartment. Use OCID instead."
  fi
fi

#### Collect Origin Information

v_orig_instJson=$(${v_oci} compute instance get --instance-id "${v_orig_instID}" | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_orig_instJson" ] || exitError "Could not get Json for compute ${v_orig_instName}."

v_orig_compID=$(echo "$v_orig_instJson" | ${v_jq} -rc '."compartment-id"') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_orig_compID" ] || exitError "Could not get the instance Compartment ID."
v_orig_compArg="--compartment-id ${v_orig_compID}"

v_orig_VnicsJson=$(${v_oci} compute instance list-vnics --all --instance-id "${v_orig_instID}" | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_orig_VnicsJson" ] || exitError "Could not get Json for vnics of ${v_orig_instName}"

v_orig_vnicPriJson=$(echo "$v_orig_VnicsJson" | ${v_jq} -rc 'select (."is-primary" == true)')
v_orig_vnicSecJson=$(echo "$v_orig_VnicsJson" | ${v_jq} -rc 'select (."is-primary" != true)')

v_orig_pubIPsJson=$(${v_oci} network public-ip list ${v_orig_compArg} --scope REGION --all | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 ] || exitError "Could not get Json for Public IPs of ${v_orig_instName}"
v_orig_reservedPubIPs=$(echo "$v_orig_pubIPsJson" | ${v_jq} -rc '."ip-address"')

v_orig_AD=$(echo "$v_orig_instJson" | ${v_jq} -rc '."availability-domain"')
[ -n "$v_orig_AD" ] || exitError "Could not get Instance Availability Domain."

v_orig_shape=$(echo "$v_orig_instJson" | ${v_jq} -rc '."shape"')
[ -n "$v_orig_shape" ] || exitError "Could not get Instance Shape."

v_orig_IP=$(echo "$v_orig_vnicPriJson" | ${v_jq} -rc '."private-ip"')
[ -n "$v_orig_IP" ] || exitError "Could not get Instance Primary Private IP Address."

v_orig_subnetID=$(echo "$v_orig_vnicPriJson" | ${v_jq} -rc '."subnet-id"')
[ -n "$v_orig_subnetID" ] || exitError "Could not get Instance Primary Subnet ID."

v_orig_BVID=$(${v_oci} compute boot-volume-attachment list ${v_orig_compArg} --availability-domain "${v_orig_AD}" --instance-id "${v_orig_instID}" | ${v_jq} -rc '.data[] | ."boot-volume-id"')
[ -n "$v_orig_BVID" ] || exitError "Could not get Instance Boot Volume ID."

v_orig_BVJson=$(${v_oci} bv boot-volume get --boot-volume-id "${v_orig_BVID}" | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_orig_BVJson" ] || exitError "Could not get Json for BV of compute ${v_orig_instName}"

v_orig_attachVolsJson=$(${v_oci} compute volume-attachment list ${v_orig_compArg} --all --instance-id "${v_orig_instID}") && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 ] || exitError "Could not get Json for Attached Volumes of ${v_orig_instName}"

#### Collect Target Information

v_all_shapes=$(${v_oci} compute shape list ${v_orig_compArg} --all | jq -r '.data[].shape' | sort -u)

if [ -z "${v_target_instName}" ]
then
  funcReadVarValidate "Target Instance Name" "$(echo "${v_orig_instName}" | sed "${v_sedrep_rule_target_name}")"
  v_target_instName="${v_return}"
fi

[ -n "${v_sedrep_rule_target_name}" ] || v_sedrep_rule_target_name="s|${v_orig_instName}|${v_target_instName}|g"

if [ -z "${v_target_shape}" ]
then
  echo "Source Instance Shape: ${v_orig_shape}"
  funcReadVarValidate "Target Instance Shape" "${v_orig_shape}" "$(echo "${v_all_shapes}" | tr "\n" "," | sed 's/,$//')" "Invalid Shape."
  v_target_shape="${v_return}"
else
  v_check=$(funcCheckValueInRange "${v_target_shape}" "$(echo "${v_all_shapes}" | tr "\n" "," | sed 's/,$//')") || true
  if [ -z "${v_check}" -o "${v_check}" == "N" ]
  then
    exitError "Shape does not exist or not available."
  fi
fi

if [ -z "${v_target_subnetID}" ]
then
  funcReadVarValidate "Create target machine in same subnet" "YES" "YES,NO" "Invalid Option."
  if [ "${v_return}" == "YES" ]
  then
    v_target_subnetID="${v_orig_subnetID}"
  else
    ## Compartment
    v_all_compJson=$(${v_oci} iam compartment list --all | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 -a -n "$v_all_compJson" ] || exitError "Could not get Json for compartments."
    v_comps_list=$(echo "${v_all_compJson}" | ${v_jq} -rc '."name"')
    v_orig_compName=$(echo "${v_all_compJson}" | ${v_jq} -rc 'select(."id" == "'${v_orig_compID}'") | ."name"')
    funcReadVarValidate "Choose a target container" "${v_orig_compName}" $(echo "${v_comps_list}" | sort | tr "\n" "," | sed 's/,$//') "Invalid Container."
    v_target_compName="${v_return}"
    v_target_compID=$(echo "${v_all_compJson}" | ${v_jq} -rc 'select(."name" == "'"${v_target_compName}"'") | ."id"')
    v_target_compArg="--compartment-id ${v_target_compID}"
    ## VCN
    v_all_vcnJson=$(${v_oci} network vcn list --all ${v_target_compArg} | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 -a -n "$v_all_vcnJson" ] || exitError "Could not get Json for VCNs."
    if [ "${v_orig_compName}" == "${v_target_compName}" ]
    then
      v_orig_VCNID=$(${v_oci} network subnet get --subnet-id $v_orig_subnetID | ${v_jq} -rc '.data."vcn-id"')
      v_orig_VCNName=$(echo "${v_all_vcnJson}" | ${v_jq} -rc 'select(."id" == "'${v_orig_VCNID}'") | ."display-name"')
    else
      v_orig_VCNName=""
    fi
    v_vcns_list=$(echo "${v_all_vcnJson}" | ${v_jq} -rc '."display-name" + " - " + ."cidr-block"')
    funcReadVarValidate "Choose a target VCN" "${v_orig_VCNName}" "$(echo "${v_vcns_list}" | sort | tr "\n" "," | sed 's/,$//')" "Invalid VCN." ' - '
    v_target_VCNName="${v_return}"
    v_target_VCNID=$(echo "${v_all_vcnJson}" | ${v_jq} -rc 'select(."display-name" == "'"${v_target_VCNName}"'") | ."id"')
    ## SubNet
    v_all_subnetJson=$(${v_oci} network subnet list --all ${v_target_compArg} --vcn-id ${v_target_VCNID} | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 -a -n "$v_all_subnetJson" ] || exitError "Could not get Json for Subnets."
    if [ "${v_orig_compName}" == "${v_target_compName}" -a "${v_orig_VCNName}" == "${v_target_VCNName}" ]
    then
      v_orig_subnetName=$(echo "${v_all_subnetJson}" | ${v_jq} -rc 'select(."id" == "'${v_orig_subnetID}'") | ."display-name"')
    else
      v_orig_subnetName=""
    fi
    v_subnets_list=$(echo "${v_all_subnetJson}" | ${v_jq} -rc '."display-name" + " - " + ."cidr-block"')
    funcReadVarValidate "Choose a target Subnet" "${v_orig_subnetName}" "$(echo "${v_subnets_list}" | sort | tr "\n" "," | sed 's/,$//')" "Invalid Subnet." ' - '
    v_target_subnetName="${v_return}"
    v_target_subnetID=$(echo "${v_all_subnetJson}" | ${v_jq} -rc 'select(."display-name" == "'"${v_target_subnetName}"'") | ."id"')
  fi
fi

v_target_subnetJson=$(${v_oci} network subnet get --subnet-id ${v_target_subnetID} | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "${v_target_subnetJson}" ] || exitError "Can't find Target Subnet."

v_all_IPs=$(${v_oci} network private-ip list --all --subnet-id ${v_target_subnetID} | ${v_jq} -rc '.data[]."ip-address"')
v_target_CIDR=$(echo "${v_target_subnetJson}" |  ${v_jq} -rc '."cidr-block"')

v_target_compID=$(echo "${v_target_subnetJson}" |  ${v_jq} -rc '."compartment-id"') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_target_compID" ] || exitError "Could not get the target Compartment ID."
v_target_compArg="--compartment-id ${v_target_compID}"

v_target_AD=$(echo "${v_target_subnetJson}" | ${v_jq} -rc '."availability-domain" // empty') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 ] || exitError "Can't find Target AD."

# For "Regional Subnets"
[ -n "${v_target_AD}" ] || v_target_AD="${v_orig_AD}"

v_target_allowPub=$(echo "${v_target_subnetJson}" | ${v_jq} -rc '."prohibit-public-ip-on-vnic"') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "${v_target_allowPub}" ] || exitError "Can't get target IP allowance."

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
    v_check=$(funcCheckValueInRange "${v_return}" "$(echo "${v_all_IPs}" | tr "\n" "," | sed 's/,$//')") || true
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

#####
#####
#####

v_step=1
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

v_VGName="${v_orig_instName}_VG"

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
v_params+=(--display-name "${v_VGName}")
v_params+=(--max-wait-seconds $v_ocicli_timeout)
v_params+=(--wait-for-state AVAILABLE)
v_params+=(--source-details "${v_volList}")
v_jsonVGCreate=$(${v_oci} bv volume-group create "${v_params[@]}") && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_jsonVGCreate" ] || exitError "Could not create Volume Group."

v_VGID=$(echo "$v_jsonVGCreate"| ${v_jq} -rc '.data."id"')

######
###  2
######

printStep

v_VGBackupName="${v_orig_instName}_VG_BKP"

v_params=()
v_params+=(--volume-group-id ${v_VGID})
v_params+=(${v_target_compArg})
v_params+=(--display-name "${v_VGBackupName}")
v_params+=(--type INCREMENTAL)
v_params+=(--wait-for-state AVAILABLE)
v_params+=(--max-wait-seconds $v_ocicli_timeout)

v_jsonVGBackup=$(${v_oci} bv volume-group-backup create "${v_params[@]}") && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_jsonVGBackup" ] || exitError "Could not create Volume Group Backup."

v_VGBackupID=$(echo "$v_jsonVGBackup"| ${v_jq} -rc '.data."id"')

######
###  3
######

printStep

v_params=()
v_params+=(--volume-group-id ${v_VGID})
v_params+=(--force)
v_params+=(--wait-for-state TERMINATED)
v_params+=(--max-wait-seconds $v_ocicli_timeout)
${v_oci} bv volume-group delete "${v_params[@]}" && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 ] || exitError "Could not remove Volume Group."

######
###  4
######

printStep

v_orig_volList=()
v_target_volList=()
v_volBkpID_list=$(echo "$v_jsonVGBackup" | ${v_jq} -rc '.data."volume-backup-ids"[]')
for v_volBkpID in $v_volBkpID_list
do
  if [ "${v_volBkpID:0:26}" == "ocid1.bootvolumebackup.oc1" ]
  then
    v_orig_BVName=$(echo "${v_orig_BVJson}" | ${v_jq} -rc '."display-name"')
    v_target_BVName=$(echo "${v_orig_BVName}" | sed "${v_sedrep_rule_target_name}")

    v_origBVBkpPolID=$(${v_oci} bv volume-backup-policy-assignment get-volume-backup-policy-asset-assignment --asset-id ${v_orig_BVID} | ${v_jq} -rc '.data[]."policy-id"') && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 ] || exitError "Could not get BV Backup Policy ID."

    v_params=()
    v_params+=(${v_target_compArg})
    v_params+=(--display-name "${v_target_BVName}")
    v_params+=(--availability-domain ${v_target_AD})
    v_params+=(--boot-volume-backup-id ${v_volBkpID})
    v_params+=(--wait-for-state AVAILABLE)
    v_params+=(--max-wait-seconds $v_ocicli_timeout)
    [ -z "${v_origBVBkpPolID}" ] || v_params+=(--backup-policy-id ${v_origBVBkpPolID})
    # --defined-tags
    v_out=$(echo "$v_orig_BVJson" | ${v_jq} -rc '."defined-tags"')
    [ -z "$v_out" -o "$v_out" == "{}" ] || v_params+=(--defined-tags "$v_out")
    # --freeform-tags
    v_out=$(echo "$v_orig_BVJson" | ${v_jq} -rc '."freeform-tags"')
    [ -z "$v_out" -o "$v_out" == "{}" ] || v_params+=(--freeform-tags "$v_out")
    #v_params+=(--size-in-gbs)

    v_target_BVJson=$(${v_oci} bv boot-volume create "${v_params[@]}") && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 -a -n "$v_target_BVJson" ] || exitError "Could not create Boot-Volume."
    v_target_BVID=$(echo "$v_target_BVJson"| ${v_jq} -rc '.data."id"')
  elif [ "${v_volBkpID:0:22}" == "ocid1.volumebackup.oc1" ]
  then
    v_orig_volID=$(${v_oci} bv backup get --volume-backup-id ${v_volBkpID} | ${v_jq} -rc '.data."volume-id"') && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 -a -n "$v_orig_volID" ] || exitError "Could not get Volume ID."
    v_orig_volJson=$(${v_oci} bv volume get --volume-id ${v_orig_volID} | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 -a -n "$v_orig_volJson" ] || exitError "Could not get Volume json."
    v_orig_VolName=$(echo "${v_orig_volJson}" | ${v_jq} -rc '."display-name"')
    v_target_VolName=$(echo "${v_orig_VolName}" | sed "${v_sedrep_rule_target_name}")

    v_origVolBkpPolID=$(${v_oci} bv volume-backup-policy-assignment get-volume-backup-policy-asset-assignment --asset-id ${v_orig_volID} | ${v_jq} -rc '.data[]."policy-id"') && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 ] || exitError "Could not get Volume Backup Policy ID."

    v_params=()
    v_params+=(${v_target_compArg})
    v_params+=(--display-name "${v_target_VolName}")
    v_params+=(--availability-domain ${v_target_AD})
    v_params+=(--volume-backup-id ${v_volBkpID})
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

    v_target_VolJson=$(${v_oci} bv volume create "${v_params[@]}") && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 -a -n "$v_target_VolJson" ] || exitError "Could not create Volume."
    v_target_volID=$(echo "$v_target_VolJson"| ${v_jq} -rc '.data."id"')
    v_orig_volList+=(${v_orig_volID})
    v_target_volList+=(${v_target_volID})
  fi
done

######
###  5
######

printStep

v_params=()
v_params+=(--volume-group-backup-id ${v_VGBackupID})
v_params+=(--force)
v_params+=(--wait-for-state TERMINATED)
v_params+=(--max-wait-seconds $v_ocicli_timeout)
v_exec=$(${v_oci} bv volume-group-backup delete "${v_params[@]}") && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 ] || echoError "Could not remove Volume Group Backup."

######
###  6
######

printStep

v_params=()

# Commented to avoid wrong names. Better to let it be generated automatically from cloned Instance Name.
## # --vnic-display-name
## v_out=$(echo "$v_orig_vnicPriJson" | ${v_jq} -rc '."display-name"')
## [ -z "$v_out" ] || v_params+=(--vnic-display-name $(echo "${v_out}" | sed "${v_sedrep_rule_target_name}"))
## # --hostname-label
## v_out=$(echo "$v_orig_vnicPriJson" | ${v_jq} -rc '."hostname-label"')
## [ -z "$v_out" ] || v_params+=(--hostname-label $(echo "${v_out}" | sed "${v_sedrep_rule_target_name}"))

# --skip-source-dest-check
v_out=$(echo "$v_orig_vnicPriJson" | ${v_jq} -rc '."skip-source-dest-check"')
[ -z "$v_out" ] || v_params+=(--skip-source-dest-check "$v_out")
# --assign-public-ip
v_out=$(echo "$v_orig_vnicPriJson" | ${v_jq} -rc '."public-ip" // empty')
if [ -n "$v_out" -a "${v_target_allowPub}" == "false" ]
then
  if grep -q -F -x "$v_out" <(echo "$v_orig_reservedPubIPs")
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
v_params+=(--source-boot-volume-id ${v_target_BVID})
v_params+=(--subnet-id ${v_target_subnetID})
v_params+=(--private-ip ${v_target_IP})
v_params+=(${v_target_compArg})

v_target_instJson=$(${v_oci} compute instance launch "${v_params[@]}") && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_target_instJson" ] || exitError "Could not create cloned Instance."

v_target_instID=$(echo "$v_target_instJson" | ${v_jq} -rc '.data."id"')

######

v_params=()
# --defined-tags
v_out=$(echo "$v_orig_vnicPriJson" | ${v_jq} -rc '."defined-tags"')
[ -z "$v_out" -o "$v_out" == "{}" ] || v_params+=(--defined-tags "$v_out")
# --freeform-tags
v_out=$(echo "$v_orig_vnicPriJson" | ${v_jq} -rc '."freeform-tags"')
[ -z "$v_out" -o "$v_out" == "{}" ] || v_params+=(--freeform-tags "$v_out")

if [ -n "${v_params[*]}" ]
then
  v_target_VnicsJson=$(${v_oci} compute instance list-vnics --all --instance-id "${v_target_instID}" | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
  [ $v_ret -eq 0 -a -n "$v_target_VnicsJson" ] || exitError "Could not get Json for vnics of ${v_target_instName}"
  v_target_vnicPriJson=$(echo "$v_target_VnicsJson" | ${v_jq} -rc 'select (."is-primary" == true) | ."id"')

  v_params+=(--vnic-id ${v_target_vnicPriJson})
  v_params+=(--force)
  # Primary VNIC update
  v_exec=$(${v_oci} network vnic update "${v_params[@]}") && v_ret=$? || v_ret=$?
  [ $v_ret -eq 0 ] || exitError "Could not update primary VNIC."
fi

######
###  7
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

  v_exec=$(${v_oci} compute volume-attachment attach "${v_params[@]}") && v_ret=$? || v_ret=$?
  [ $v_ret -eq 0 ] || exitError "Could not associate cloned Volume."

  v_i=$((v_i+1))
done

######
###  8
######

printStep

v_target_imageID=$(echo "$v_target_instJson" | ${v_jq} -rc '.data."image-id"')
v_target_imageJson=$(${v_oci} compute image get --image-id ${v_target_imageID}) && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_target_imageJson" ] || exitError "Could not get Image json."
v_target_SO=$(echo "$v_target_imageJson" | ${v_jq} -rc '.data."operating-system"')

if [ "${v_target_SO}" == "Windows" ]
then
  echo "SCRIPT EXECUTED SUCCESSFULLY"
  exit 0
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

if [ -n "${v_iscsiadm}" ]
then

  v_script_ask="yes"
  sshExecute "${v_target_IP}" "${v_iscsiadm}"

  ## Restart Machine
  echo 'Bouncing the instance..'
  v_params=()
  v_params+=(--instance-id "${v_target_instID}")
  v_params+=(--action SOFTRESET)
  v_params+=(--wait-for-state RUNNING)
  v_params+=(--max-wait-seconds $v_ocicli_timeout)
  
  ${v_oci} compute instance action "${v_params[@]}" >&- && v_ret=$? || v_ret=$?
  [ $v_ret -eq 0 ] || exitError "Not able to bounce the instance."

fi

######
######
######

echo "SCRIPT EXECUTED SUCCESSFULLY"
exit 0

## TODO: SECONDARY VNICS