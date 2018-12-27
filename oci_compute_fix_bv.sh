#!/bin/bash
#************************************************************************
#
#   oci_compute_fix_bv.sh - Fix the BV of a compute instance attaching
#   and mounting it into another compute.
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
# Version 1.03
#************************************************************************
set -e

# Define paths for oci-cli and jq or put them on $PATH. Don't use relative PATHs in the variables below.
v_oci="oci"
v_jq="jq"

# Add any desired oci argument. Keep default to avoid oci_cli_rc usage (recommended).
v_oci_args="--cli-rc-file /dev/null"

# Don't change it.
v_min_ocicli="2.4.30"

read -r -d '' v_all_steps << EOM || true
## Macro Steps
# 1  - Stop Target Compute for Boot Volume fix.
# 2  - Detach the BV.
# 3  - Start "Support instance" if not started.
# 4  - Attach the BV as a extra Volume on a "Support instance".
# 5  - Mount the BV.
# 6  - Wait for Recovery Actions by User.
# 7  - Umount the BV.
# 8  - Detach the BV from the "Support instance".
# 9  - Attach back BV in Target Compute.
# 10 - Start Target Compute.
EOM


####
#### INTERNAL - PROVIDE HERE OR AS PARAMETERS.
####
v_support_usePublicIP="no"  # Define if use Public IP to connect on support instance for iscsiadm commands. Values: "yes" or "no".
v_oci_region=""             # Define if don't want to use the current one set in oci config file.
v_script_ask="yes"          # Define if don't want the script to pause and ask questions. Values: "yes" or "no".
v_script_steps="all"        # Define if you want the script to pause and ask questions. Values: "all", "mount" or "umount".
v_script_root_partition=3   # Define the default partition to mount from the Boot Volume of the Target Instance.
####

# Helpful functions

function echoError ()
{
   (>&2 echo "$1")
}

function exitError ()
{
   echoError "$1"
   ( set -o posix ; set ) > /tmp/oci_debug.txt
   exit 1
}

# trap
trap 'exitError "Code Interrupted."' INT SIGINT SIGTERM

if [ $# -lt 2 -o $# -gt 5 ]
then
  echoError "$0: Two arguments are needed.. given: $#"
  echoError "- 1st param = Target Compute Name or OCID"
  echoError "- 2nd param = Support Compute Name or OCID"
  echoError "- 3rd param = Region (optional)"
  echoError "- 4th param = Ask? (optional)"
  echoError "- 5th param = Steps to be executed (optional)"
  exit 1
fi

v_target_instName="$1"
v_support_instName="$2"
[ -n "$3" ] && v_oci_region="$3"
[ -n "$4" ] && v_script_ask="$4"
[ -n "$5" ] && v_script_steps="$5"
[ -n "${v_oci_region}" ] && v_oci_args="${v_oci_args} --region ${v_oci_region}"

[ -z "$v_target_instName" ]  && exitError "Target Compute Name or OCID can't be null."
[ -z "$v_support_instName" ] && exitError "Support Compute Name or OCID can't be null."

if [ "${v_support_usePublicIP}" != "yes" -a "${v_support_usePublicIP}" != "no" ]
then
  exitError "Valid values for \"\$v_support_usePublicIP\" are \"yes\" or \"no\"."
fi

if [ "${v_script_ask}" != "yes" -a "${v_script_ask}" != "no" ]
then
  exitError "Valid values for \"\$v_script_ask\" are \"yes\" or \"no\"."
fi

if [ "${v_script_steps}" != "all" -a "${v_script_steps}" != "mount" -a "${v_script_steps}" != "umount" ]
then
  exitError "Valid values for \"\$v_script_steps\" are \"all\", \"mount\" or \"umount\"."
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

v_ocicli_timeout=3600

[ -z "${v_oci_args}" ] || v_oci="${v_oci} ${v_oci_args}"

#### BEGIN

#### Validade OCI-CLI and PARAMETER

v_test=$(${v_oci} iam compartment list --all 2>&1) && v_ret=$? || v_ret=$?
if [ $v_ret -ne 0 ]
then
  echoError "oci-cli not able to run \"${v_oci} iam compartment list --all\". Please check error:"
  echoError "$v_test"
  exit 1
fi

#### Target Instance

function getInstanceID ()
{
  # Receives a parameter that can be either the Compute OCID or Display Name. Returns the Intance OCID and Display Name.
  # If Display Name is duplicated on the region, returns an error.
  local v_instID v_instName v_comp v_list_comps v_ret v_out
  v_instName="$1"
  if [ "${v_instName:0:18}" == "ocid1.instance.oc1" ]
  then
    v_instID=$(${v_oci} compute instance get --instance-id "${v_instName}" | ${v_jq} -rc '.data | select(."lifecycle-state" != "TERMINATED") | ."id"') && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 -a -n "$v_instID" ] || exitError "Could not find a compute with the provided OCID."
    v_instName=$(${v_oci} compute instance get --instance-id "${v_instID}" | ${v_jq} -rc '.data."display-name"') && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 -a -n "$v_instName" ] || exitError "Could not get Display Name of compute ${v_instID}"
  else
    v_list_comps=$(${v_oci} iam compartment list --all | ${v_jq} -rc '.data[] | select(."lifecycle-state" != "TERMINATED") | ."id"') && v_ret=$? || v_ret=$?
    [ $v_ret -eq 0 -a -n "$v_list_comps" ] || exitError "Could not list Compartments."
    for v_comp in $v_list_comps
    do
      v_out=$(${v_oci} compute instance list --compartment-id "$v_comp" --all | ${v_jq} -rc '.data[] | select(."display-name" == "'"${v_instName}"'" and ."lifecycle-state" != "TERMINATED") | ."id"') && v_ret=$? || v_ret=$?
      [ $v_ret -eq 0 ] || exitError "Could not search the OCID of compute ${v_instName} in compartment ${v_comp}. Use OCID instead."
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

v_out=$(getInstanceID "${v_target_instName}")
read v_target_instID v_target_instName <<< $(echo "${v_out}" | awk -F'|' '{print $1, $2}')

v_target_instJson=$(${v_oci} compute instance get --instance-id "${v_target_instID}" | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_target_instJson" ] || exitError "Could not get Json for compute ${v_target_instName}"

v_target_compID=$(echo "$v_target_instJson" | ${v_jq} -rc '."compartment-id"') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_target_compID" ] || exitError "Could not get the instance Compartment ID."
v_target_compArg="--compartment-id ${v_target_compID}"

v_target_instAD=$(echo "$v_target_instJson" | ${v_jq} -rc '."availability-domain"')
v_target_instState=$(echo "$v_target_instJson" | ${v_jq} -rc '."lifecycle-state"')

v_target_BVAttachJson=$(${v_oci} compute boot-volume-attachment list ${v_target_compArg} --availability-domain "${v_target_instAD}" --instance-id "${v_target_instID}") && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_target_BVAttachJson" ] || exitError "Could not get Json for BV attachment of ${v_target_instName}"

v_target_BVAttachID=$(echo "${v_target_BVAttachJson}" | ${v_jq} -rc '.data[] | ."id"')
[ -n "$v_target_BVAttachID" ] || exitError "Could not get Instance Boot Volume Attachment ID."
v_target_BVAttachState=$(echo "${v_target_BVAttachJson}" | ${v_jq} -rc '.data[] | ."lifecycle-state"')
[ -n "$v_target_BVAttachState" ] || exitError "Could not get Instance Boot Volume Attachment State."
v_target_BVID=$(echo "${v_target_BVAttachJson}" | ${v_jq} -rc '.data[] | ."boot-volume-id"')
[ -n "$v_target_BVID" ] || exitError "Could not get Instance Boot Volume ID."

v_target_imageID=$(echo "$v_target_instJson" | ${v_jq} -rc '."image-id"')
v_target_imageJson=$(${v_oci} compute image get --image-id ${v_target_imageID}) && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_target_imageJson" ] || exitError "Could not get Image json."
v_target_OS=$(echo "$v_target_imageJson" | ${v_jq} -rc '.data."operating-system"')

#### Support Instance

v_out=$(getInstanceID "${v_support_instName}")
read v_support_instID v_support_instName <<< $(echo "${v_out}" | awk -F'|' '{print $1, $2}')

v_support_instJson=$(${v_oci} compute instance get --instance-id "${v_support_instID}" | ${v_jq} -rc '.data') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_support_instJson" ] || exitError "Could not get Json for compute ${v_support_instName}"

v_support_compID=$(echo "$v_support_instJson" | ${v_jq} -rc '."compartment-id"') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_support_compID" ] || exitError "Could not get the instance Compartment ID."
v_support_compArg="--compartment-id ${v_support_compID}"

v_support_instAD=$(echo "$v_support_instJson" | ${v_jq} -rc '."availability-domain"')
v_support_instState=$(echo "$v_support_instJson" | ${v_jq} -rc '."lifecycle-state"')

v_support_vnicsJson=$(${v_oci} compute instance list-vnics --all --instance-id "${v_support_instID}" | ${v_jq} -rc '.data[]') && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 -a -n "$v_support_vnicsJson" ] || exitError "Could not get Json for vnics of ${v_support_instName}"

if [ "${v_support_usePublicIP}" == "no" ]
then
  v_support_IP=$(echo "$v_support_vnicsJson" | ${v_jq} -rc 'select (."is-primary" == true) | ."private-ip"')
  [ -n "$v_support_IP" ] || exitError "Could not get Instance Primary Private IP Address."
else
  v_support_IP=$(echo "$v_support_vnicsJson" | ${v_jq} -rc 'select (."is-primary" == true) | ."public-ip" // empty')
  [ -n "$v_support_IP" ] || exitError "Could not get Instance Primary Public IP Address."
fi

if [ "${v_target_compID}" != "${v_support_compID}" ]
then
  exitError "Target Instance and Support Instance must be in same Compartment."
fi

if [ "${v_target_instAD}" != "${v_support_instAD}" ]
then
  exitError "Target Instance and Support Instance must be in same AD."
fi

[ "${v_script_steps}" == "all" -o "${v_script_steps}" == "mount" ] && v_exec_step1="yes" || v_exec_step1="no"
[ "${v_script_steps}" == "all" -o "${v_script_steps}" == "mount" ] && v_exec_step2="yes" || v_exec_step2="no"
[ "${v_script_steps}" == "all" -o "${v_script_steps}" == "mount" ] && v_exec_step3="yes" || v_exec_step3="no"
[ "${v_script_steps}" == "all" -o "${v_script_steps}" == "mount" ] && v_exec_step4="yes" || v_exec_step4="no"
[ "${v_script_steps}" == "all" -o "${v_script_steps}" == "mount" ] && v_exec_step5="yes" || v_exec_step5="no"
[ "${v_script_steps}" == "all" ] && v_exec_step6="yes" || v_exec_step6="no"
[ "${v_script_steps}" == "all" -o "${v_script_steps}" == "umount" ] && v_exec_step7="yes" || v_exec_step7="no"
[ "${v_script_steps}" == "all" -o "${v_script_steps}" == "umount" ] && v_exec_step8="yes" || v_exec_step8="no"
[ "${v_script_steps}" == "all" -o "${v_script_steps}" == "umount" ] && v_exec_step9="yes" || v_exec_step9="no"
[ "${v_script_steps}" == "all" -o "${v_script_steps}" == "umount" ] && v_exec_step10="yes" || v_exec_step10="no"

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

if [ "${v_exec_step1}" == "yes" ]
then
  if [ "${v_target_instState}" != "STOPPED" ]
  then
    v_params=()
    v_params+=(--instance-id ${v_target_instID})
    v_params+=(--action STOP)
    v_params+=(--max-wait-seconds $v_ocicli_timeout)
    v_params+=(--wait-for-state STOPPED)

    ${v_oci} compute instance action "${v_params[@]}" >&- && v_ret=$? || v_ret=$?
    [ $v_ret -ne 0 ] && exitError "Could not stop Target Compute."

    v_target_instState="STOPPED"
  else
    echo "Instance already stopped."
  fi
else
  echo "Skipped."
fi

######
###  2
######

printStep

if [ "${v_exec_step2}" == "yes" ]
then
  if [ "$v_target_BVAttachState" == "ATTACHED" ]
  then
    v_params=()
    v_params+=(--boot-volume-attachment-id ${v_target_BVAttachID})
    v_params+=(--force)
    v_params+=(--wait-for-state DETACHED)
    v_params+=(--max-wait-seconds $v_ocicli_timeout)

    ${v_oci} compute boot-volume-attachment detach "${v_params[@]}" && v_ret=$? || v_ret=$?
    [ $v_ret -ne 0 ] && exitError "Could not detach BV from instance."

    v_target_BVAttachState="DETACHED"
  else
    echo "BV already detached."
  fi
else
  echo "Skipped."
fi

######
###  3
######

printStep

if [ "${v_exec_step3}" == "yes" ]
then
  if [ "${v_support_instState}" != "RUNNING" ]
  then
    v_params=()
    v_params+=(--instance-id ${v_support_instID})
    v_params+=(--action START)
    v_params+=(--max-wait-seconds $v_ocicli_timeout)
    v_params+=(--wait-for-state RUNNING)

    ${v_oci} compute instance action "${v_params[@]}" >&- && v_ret=$? || v_ret=$?
    [ $v_ret -ne 0 ] && exitError "Could not start Support Compute."
  else
    echo "Instance already running."
  fi
else
  echo "Skipped."
fi

######
###  4
######

printStep

v_support_attachVolJson=$(${v_oci} compute volume-attachment list ${v_target_compArg} --instance-id "${v_support_instID}" --volume-id "${v_target_BVID}" | jq '.data[] | select (."lifecycle-state" == "ATTACHED")')
[ -z "${v_support_attachVolJson}" ] && v_support_attachVolState="DETACHED" || v_support_attachVolState="ATTACHED"

if [ "${v_exec_step4}" == "yes" ]
then
  if [ "${v_support_attachVolState}" == "DETACHED" ]
  then
    v_params=()
    v_params+=(--instance-id ${v_support_instID})
    v_params+=(--type iscsi)
    v_params+=(--volume-id "${v_target_BVID}")
    v_params+=(--is-read-only false)
    v_params+=(--wait-for-state ATTACHED)
    v_params+=(--max-wait-seconds $v_ocicli_timeout)

    v_support_attachVolJson=$(${v_oci} compute volume-attachment attach "${v_params[@]}" | jq '.data') && v_ret=$? || v_ret=$?
    [ $v_ret -ne 0 -o -z "${v_support_attachVolJson}" ] && exitError "Could not attach BV as Volume."

    v_support_attachVolState="ATTACHED"
  else
    echo "Volume already attached."
  fi
else
  echo "Skipped."
fi

if [ "${v_support_attachVolState}" == "ATTACHED" ]
then
  v_support_attachVolID=$(echo "$v_support_attachVolJson" | ${v_jq} -rc '."id"')
  [ -z "${v_support_attachVolID}" ] && exitError "Could not get attachment ID."
fi

######
###  5
######

printStep

v_skip_mount=0
if [ "${v_target_OS}" == "Windows" ]
then
  [ "${v_exec_step5}" == "yes" ] && echo "Skipping Mount. OS is Windows."
  v_skip_mount=1
fi

if [ -z "${v_support_attachVolJson}" ]
then
  [ "${v_exec_step5}" == "yes" ] && echo "Skipping Mount. Volume not Attached."
  v_skip_mount=1
fi


v_iqn=$(echo "$v_support_attachVolJson" | ${v_jq} -rc '."iqn"')
v_ipv4=$(echo "$v_support_attachVolJson" | ${v_jq} -rc '."ipv4"')
v_port=$(echo "$v_support_attachVolJson" | ${v_jq} -rc '."port"')
v_iscsiadm_mount=""
v_iscsiadm_mount+="set -x"$'\n'
v_iscsiadm_mount+="sudo iscsiadm -m node -o new -T ${v_iqn} -p ${v_ipv4}:${v_port}"$'\n'
v_iscsiadm_mount+="sudo iscsiadm -m node -o update -T ${v_iqn} -n node.startup -v automatic"$'\n'
v_iscsiadm_mount+="sudo iscsiadm -m node -T ${v_iqn} -p ${v_ipv4}:${v_port} -l"$'\n'
v_iscsiadm_mount+="sleep 5"$'\n'
v_iscsiadm_mount+="set -e"$'\n'
v_iscsiadm_mount+="v_sdname=\$(ls -l /dev/disk/by-path | grep \"${v_ipv4}\" | sed 's/.*\///' | grep -e '${v_script_root_partition}\$')"$'\n'
v_iscsiadm_mount+="v_partition=\"/dev/\${v_sdname}\""$'\n'
v_iscsiadm_mount+="sudo mkdir /${v_target_instName} || true"$'\n'
v_iscsiadm_mount+="v_type=\$(sudo file -s \${v_partition})"$'\n'
v_iscsiadm_mount+="if [[ \$v_type == *\"XFS\"* ]]; then"$'\n'
v_iscsiadm_mount+="  v_option='nouuid,_netdev,_rnetdev'"$'\n'
v_iscsiadm_mount+="elif  [[ \$v_type == *\"ext4\"* ]]; then"$'\n'
v_iscsiadm_mount+="  v_option='_netdev'"$'\n'
v_iscsiadm_mount+="fi"$'\n'
v_iscsiadm_mount+="sudo mount -o \${v_option} \${v_partition} /${v_target_instName} || true"$'\n'

v_iscsiadm_umount=""
v_iscsiadm_umount+="set -x"$'\n'
v_iscsiadm_umount+="v_sdname=\$(ls -l /dev/disk/by-path | grep \"${v_ipv4}\" | sed 's/.*\///' | grep -e '${v_script_root_partition}\$')"$'\n'
v_iscsiadm_umount+="[ -z \"\${v_sdname}\" ] && exit 0"$'\n'
v_iscsiadm_umount+="set -e"$'\n'
v_iscsiadm_umount+="v_partition=\"/dev/\${v_sdname}\""$'\n'
v_iscsiadm_umount+="sudo umount -l \${v_partition} || true"$'\n'
v_iscsiadm_umount+="sudo rmdir /${v_target_instName} || true"$'\n'
v_iscsiadm_umount+="sleep 5"$'\n'
v_iscsiadm_umount+="set +e"$'\n'
v_iscsiadm_umount+="sudo iscsiadm -m node -T ${v_iqn} -p ${v_ipv4}:${v_port} -u"$'\n'
v_iscsiadm_umount+="sudo iscsiadm -m node -o delete -T ${v_iqn} -p ${v_ipv4}:${v_port}"$'\n'

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
    echo -n "Type \"YES\" to apply the changes via SSH as opc@${v_support_IP}: "
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

if [ "${v_exec_step5}" == "yes" ]
then
  if [ "$v_skip_mount" -eq 0 ]
  then
    sshExecute "${v_support_IP}" "${v_iscsiadm_mount}"
  fi
else
  echo "Skipped."
fi

######
###  6
######

printStep

if [ "${v_exec_step6}" == "yes" ]
then
  echo "Now connect on the instance IP ${v_support_IP} and perform recovery actions on /${v_target_instName}/"
  v_read=""
  while [ "${v_read}" != "CONTINUE" ]
  do
    echo "Type \"CONTINUE\" when finished."
    read v_read
  done
else
  echo "Skipped."
fi

######
###  7
######

printStep

if [ "${v_exec_step7}" == "yes" ]
then
  if [ "$v_skip_mount" -eq 0 ]
  then
    sshExecute "${v_support_IP}" "${v_iscsiadm_umount}"
  fi
else
  echo "Skipped."
fi

######
###  8
######

printStep

if [ "${v_exec_step8}" == "yes" ]
then
  if [ "${v_support_attachVolState}" == "ATTACHED" ]
  then
    v_params=()
    v_params+=(--volume-attachment-id ${v_support_attachVolID})
    v_params+=(--force)
    v_params+=(--wait-for-state DETACHED)
    v_params+=(--max-wait-seconds $v_ocicli_timeout)

    ${v_oci} compute volume-attachment detach "${v_params[@]}" && v_ret=$? || v_ret=$?
    [ $v_ret -ne 0 ] && exitError "Could not attach BV as Volume."

    v_support_attachVolState="DETACHED"
  else
    echo "Volume already detached."
  fi
else
  echo "Skipped."
fi

######
###  9
######

printStep

if [ "${v_exec_step9}" == "yes" ]
then
  if [ "$v_target_BVAttachState" == "DETACHED" ]
  then
    v_params=()
    v_params+=(--boot-volume-id ${v_target_BVID})
    v_params+=(--instance-id ${v_target_instID})
    v_params+=(--wait-for-state ATTACHED)
    v_params+=(--max-wait-seconds $v_ocicli_timeout)

    ${v_oci} compute boot-volume-attachment attach "${v_params[@]}" >&- && v_ret=$? || v_ret=$?
    [ $v_ret -ne 0 ] && exitError "Could not attach BV back on instance."

    v_target_BVAttachState="ATTACHED"
  else
    echo "BV already attached."
  fi
else
  echo "Skipped."
fi

######
### 10
######

printStep

if [ "${v_exec_step10}" == "yes" ]
then
  if [ "${v_target_instState}" == "STOPPED" ]
  then
    v_params=()
    v_params+=(--instance-id ${v_target_instID})
    v_params+=(--action START)
    v_params+=(--max-wait-seconds $v_ocicli_timeout)
    v_params+=(--wait-for-state RUNNING)

    ${v_oci} compute instance action "${v_params[@]}" >&- && v_ret=$? || v_ret=$?
    [ $v_ret -ne 0 ] && exitError "Could not start Target Compute."

    v_target_instState="RUNNING"
  else
    echo "Instance already running."
  fi
else
  echo "Skipped."
fi

### END

echo "SCRIPT EXECUTED SUCCESSFULLY"
exit 0