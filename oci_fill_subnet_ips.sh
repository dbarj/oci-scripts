#!/bin/bash
#************************************************************************
#
#   oci_fill_subnet_ips.sh - Create a compute that will use all IPs in
#   subnet.
#
#   Copyright 2019 Rodrigo Jorge <http://www.dbarj.com.br/>
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

####
#### INTERNAL - MUST BE PROVIDED HERE OR AS PARAMETERS.
####
v_subnet_ocid=''
v_ip_exception=''
v_script_ask="yes"

# Define paths for oci-cli and jq or put them on $PATH. Don't use relative PATHs in the variables below.
v_oci="oci"
v_jq="jq"

# Add any desired oci argument. Keep default to avoid oci_cli_rc usage (recommended).
[ -n "${OCI_CLI_ARGS}" ] && v_oci_args="${OCI_CLI_ARGS}"
[ -z "${OCI_CLI_ARGS}" ] && v_oci_args="--cli-rc-file /dev/null"

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

function dec2ip () {
    local delim ip dec=$@
    for e in {3..0}
    do
        ((octet = dec / (256 ** e) ))
        ((dec -= octet * 256 ** e))
        ip+=$delim$octet
        delim=.
    done
    printf '%s\n' "$ip"
}


function ips_in_subnet ()
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
  local ip mask netmask sub sub_ip rval start end
  
  # Define bitmask.
  local readonly BITMASK=0xFFFFFFFF
  
  # Set DEBUG status if not already defined in the script.
  [[ "${DEBUG}" == "" ]] && DEBUG=0
  
  # Read arguments.
  IFS=/ read sub mask <<< "${1}"
  IFS=. read -a sub_ip <<< "${sub}"
  
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
  
  # Removing Network, Gateway and Broadcast:
  ((start+=2))
  ((end-=1))
  
  # Determine if IP in range.
  ip=$start
  while true
  do
    (( $ip <= $end )) || break
     dec2ip $ip
    ((ip++))
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

[ -n "$1" ] && v_subnet_ocid="$1"
[ -n "$2" ] && v_ip_exception="$2"

if [ -z "${v_subnet_ocid}" -o $# -gt 2 ]
then
  echoStatus "This tool will fill the desired Subnet with all availables IPs."
  echoStatus "You need to specify 2 parameters to run this tool."
  echoStatus "- 1st param = Subnet OCID"
  echoStatus "- 2nd param = List of IPs to skip (comma separated)"
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

v_ocicli_timeout=1200

[ -z "${v_oci_args}" ] || v_oci="${v_oci} ${v_oci_args}"
v_oci_orig="${v_oci}"

####################
## PROGRAM STARTS
####################

v_subnetJson=$(${v_oci} network subnet get --subnet-id ${v_subnet_ocid} | jq '.data') && v_ret=$? || v_ret=$?
checkError "$v_subnetJson" "$v_ret" "Could not find a subnet with the provided OCID."

v_subnetAD=$(jq -rc '."availability-domain"' <<< "${v_subnetJson}")
v_subnetComp=$(jq -rc '."compartment-id"' <<< "${v_subnetJson}")
v_subnetCIDR=$(jq -rc '."cidr-block"' <<< "${v_subnetJson}")

v_ipsJson=$(${v_oci} network private-ip list --subnet-id ${v_subnet_ocid} --all | jq '.data[]') && v_ret=$? || v_ret=$?
checkError "$v_ipsJson" "$v_ret" "Could not json of IPs."

v_ipsUsed=$(echo "$v_ipsJson" | jq -rc '."ip-address"')

v_imageJson=$(${v_oci} compute image list --compartment-id ${v_subnetComp} --all | jq '[.data[] | select(."base-image-id" == null and ."operating-system"=="Oracle Linux") | select(."display-name" | contains("GPU") | not) ][1]') && v_ret=$? || v_ret=$?
checkError "$v_imageJson" "$v_ret" "Could not find a image."

v_imageID=$(jq -rc '."id"' <<< "${v_imageJson}") && v_ret=$? || v_ret=$?
checkError "$v_imageID" "$v_ret" "Could not get image OCID."

v_ipsCIDR=$(ips_in_subnet ${v_subnetCIDR}) && v_ret=$? || v_ret=$?
checkError "$v_ipsCIDR" "$v_ret" "Could not get IPs in CIDR ${v_subnetCIDR}."

v_ips2Burn=$(comm -2 -3 <(echo "${v_ipsCIDR}" | sort -u) <(echo "${v_ipsUsed}" | sort -u)) && v_ret=$? || v_ret=$?
checkError "$v_ips2Burn" "$v_ret" "Could not find any non-used IP."

v_ip_exception=$(echo "${v_ip_exception}" | tr "," "\n")
[ -n "${v_ip_exception}" ] && v_ips2Burn=$(comm -2 -3 <(echo "${v_ips2Burn}" | sort -u) <(echo "${v_ip_exception}" | sort -u))
checkError "$v_ips2Burn" 0 "Could not find any non-used IP after aplying exception list."

v_ips2Burn=$(echo "${v_ips2Burn}" | sort -V)

function getNextIP ()
{
  v_ip=$(echo "$v_ips2Burn" | head -n 1)
  v_ips2Burn=$(sed '1d' <(echo "$v_ips2Burn"))
  [ -z "${v_ip}" ] && echoStatus "All IPs burned." "BOLD" && exit 0
  return 0
}

function stopInstance ()
{
  v_params=()
  v_params+=(--instance-id ${v_compID})
  v_params+=(--action STOP)
  v_params+=(--wait-for-state STOPPED)
  v_params+=(--max-wait-seconds 1200)
  
  echoStatus "Stopping Dummy instance."
  v_compJson=$(${v_oci} compute instance action "${v_params[@]}") && v_ret=$? || v_ret=$?
}

v_ips2Burn_Tot=$(echo "${v_ips2Burn}" | wc -l)

v_warning=100
if [ $v_ips2Burn_Tot -ge $v_warning -a "$v_script_ask" == "yes" ]
then
  echoStatus "The script will create temporary machines to allocate $v_ips2Burn_Tot IPs." "BOLD"
  echo -n "Type \"YES\" to execute it and apply the changes: "
  read v_input
  [ "$v_input" == "YES" -o "$v_input" == "yes" -o "$v_input" == "Y" -o "$v_input" == "y" ] || exitError "Script aborted."
fi

v_max_ip_per_subnet=32

while true
do

  v_ips2Burn_Tot=$(echo "${v_ips2Burn}" | wc -l)
  v_num_subnets=$(((v_ips2Burn_Tot+(v_max_ip_per_subnet-1))/v_max_ip_per_subnet))

  if [ $v_num_subnets -le 2 ]
  then
    v_subs=2
    v_shape='VM.Standard2.1'
  elif [ $v_num_subnets -le 4 ]
  then
    v_subs=4
    v_shape='VM.Standard2.4'
  elif [ $v_num_subnets -le 8 ]
  then
    v_subs=8
    v_shape='VM.Standard2.8'
  elif [ $v_num_subnets -le 16 ]
  then
    v_subs=16
    v_shape='VM.Standard2.16'
  elif [ $v_num_subnets -le 24 ]
  then
    v_subs=24
    v_shape='VM.Standard2.24'
  fi

  getNextIP

  echoStatus "Total IPs to burn: $v_ips2Burn_Tot"
  
  v_params=()
  v_params+=(--availability-domain ${v_subnetAD})
  v_params+=(--compartment-id ${v_subnetComp})
  v_params+=(--shape ${v_shape})
  v_params+=(--display-name "BURN_IPS")
  v_params+=(--image-id ${v_imageID})
  v_params+=(--subnet-id ${v_subnet_ocid})
  v_params+=(--wait-for-state RUNNING)
  v_params+=(--max-wait-seconds 1200)
  v_params+=(--assign-public-ip false)
  v_params+=(--private-ip ${v_ip})
  
  echoStatus "Creating Dummy instance to hold your IPs."
  echoStatus "This instance is able to hold up to $((v_subs*v_max_ip_per_subnet)) IPs."
  v_compJson=$(${v_oci} compute instance launch "${v_params[@]}") && v_ret=$? || v_ret=$?
  checkError "$v_compJson" "$v_ret" "Unable to create compute."
  
  v_ips2Burn_Tot=$(echo "${v_ips2Burn}" | wc -l)
  
  v_compID=$(jq -rc '.data."id"' <<< "${v_compJson}") && v_ret=$? || v_ret=$?
  checkError "$v_compID" "$v_ret" "Could not get compute OCID."

  v_cur_sub=2
  v_ips2Burn_Tot=$((v_ips2Burn_Tot-v_max_ip_per_subnet))
  while [ $v_cur_sub -le $v_subs -a $v_ips2Burn_Tot -gt 0 ]
  do
    getNextIP
      
    v_params=()
    v_params+=(--instance-id ${v_compID})
    v_params+=(--subnet-id ${v_subnet_ocid})
    v_params+=(--assign-public-ip false)
    v_params+=(--private-ip ${v_ip})
    v_params+=(--wait)
    
    echoStatus "Adding VNIC ${v_cur_sub} to this compute."
    v_compVnic=$(${v_oci} compute instance attach-vnic "${v_params[@]}") && v_ret=$? || v_ret=$?
    checkError "$v_compVnic" "$v_ret" "Could not create an extra VNIC."
    ((v_cur_sub++))
    v_ips2Burn_Tot=$((v_ips2Burn_Tot-v_max_ip_per_subnet))
  done

  stopInstance

  # Get VNICs
  l_compVnicIDs=$(${v_oci} compute instance list-vnics --all --instance-id "${v_compID}" | ${v_jq} -rc '.data[] | ."id"')
    
  for v_compVnicIDs in $l_compVnicIDs
  do
    v_ip_count=$(oci --region us-phoenix-1 network private-ip list --vnic-id ${v_compVnicIDs} --all | jq '.data | length')
    
    while [ $v_ip_count -lt $v_max_ip_per_subnet ]
    do
      getNextIP
      v_params=()
      v_params+=(--vnic-id ${v_compVnicIDs})
      v_params+=(--ip-address ${v_ip})
      echoStatus "Adding ${v_ip}"
      v_ipJson=$(${v_oci} network vnic assign-private-ip "${v_params[@]}") && v_ret=$? || v_ret=$?
      checkError "X" "$v_ret" "Could not assign Private IP."
    
      ((v_ip_count++))
    done
  done
done

exit 0
###