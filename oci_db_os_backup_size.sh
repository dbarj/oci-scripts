#!/bin/bash
#************************************************************************
#
#   oci_db_os_backup_size.sh - Return in bytes the space used by DBaaS
#   Object Storage backups.
#
#   Copyright 2020  Rodrigo Jorge <http://www.dbarj.com.br/>
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
# Created on: Oct/2020 by Rodrigo Jorge
# Version 1.02
#************************************************************************
set -eo pipefail

if [ -z "${BASH_VERSION}" -o "${BASH}" = "/bin/sh" ]
then
  >&2 echo "Script must be executed in BASH shell."
  exit 1
fi

# If DEBUG variable is undefined, change to 1.
[[ "${DEBUG}" == "" ]] && DEBUG=0
[ ! -z "${DEBUG##*[!0-9]*}" ] || DEBUG=0

trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM

function echoError ()
{
  (>&2 echo "$1")
}

function exitError ()
{
   echoError "$1"
   exit 1
}

function echoDebug ()
{
  local v_msg="$1"
  local v_debug_lvl="$2"
  local v_filename="${v_this_script%.*}.log"
  [ -z "${v_debug_lvl}" ] && v_debug_lvl=1
  if [ $DEBUG -ge ${v_debug_lvl} ]
  then
    v_msg="$(date '+%Y%m%d%H%M%S'): $v_msg"
    [ -n "${v_exec_id}" ] && v_msg="$v_msg (${v_exec_id})"
    echo "$v_msg" >> "${v_filename}"
    [ -f "../${v_filename}" ] && echo "$v_msg" >> "../${v_filename}"
  fi
  return 0
}

v_this_script="$(basename -- "$0")"

v_opc_file="$1"

if [ "${v_opc_file}" = "-h" -o  "${v_opc_file}" = "--help" ]
then
  echoError "Usage: ${v_this_script} <OPC_CONFIG_FILE>"
  echoError ""
  echoError "This script will return the total space used by your database in the object storage."
  echoError ""
  echoError "<OPC_CONFIG_FILE> - opc configuration file. Empty = auto-detect."
  exit 1
fi


if ! $(which curl >&- 2>&-)
then
  exitError "Could not find curl binary. Please adapt the path in the script if not in \$PATH."
fi

function getOPCfromDB ()
{
    set -eo pipefail
    sqlplus -L -S / as sysdba <<'EOF'
set lines 1000 pages 0 hea off feed off
select distinct replace(replace(regexp_substr(value,'OPC_PFILE=.*\)'),'OPC_PFILE=',''),')','') value from v$rman_configuration where name='CHANNEL';
EOF
}

set +e
if [ -z "${v_opc_file}" ]
then
  v_opc_file=$(getOPCfromDB 2>&-)
  v_ret=$?
  if [ $v_ret -ne 0 -o -z "${v_opc_file}" ]
  then
    v_opc_file=$(ls -1 /opt/oracle/dcs/commonstore/objectstore/opc_pfile/*/*.ora | head -n 1)
    v_ret=$?
    if [ $v_ret -ne 0 -o -z "${v_opc_file}" ]
    then
      exitError "Could not auto-detect the OPC configuration file. Please provide as parameter."
    fi
  fi
fi
set -eo pipefail

[ ! -r "${v_opc_file}" ] && exitError "File \"${v_opc_file}\" not found readable."

v_mkstore="mkstore"
if ! $(which ${v_mkstore} >&- 2>&-)
then
  v_orahome="$(cat /etc/oratab | cut -f 2 -d: | head -n 1)"
  [ ! -d "${v_orahome}" ] && exitError "Could not find ORACLE_HOME."
  v_mkstore="${v_orahome}/bin/mkstore"
  if ! $(which ${v_mkstore} >&- 2>&-)
  then
    exitError "Could not find mkstore on \"${v_mkstore}\"."
  fi
fi

#############
### START ###
#############

source "${v_opc_file}"

[ -z "${OPC_HOST}" ] && exitError "OPC_HOST not defined on \"${v_opc_file}\"."
[ -z "${OPC_WALLET}" ] && exitError "OPC_WALLET not defined on \"${v_opc_file}\"."
[ -z "${OPC_CONTAINER}" ] && exitError "OPC_CONTAINER not defined on \"${v_opc_file}\"."

eval "${OPC_WALLET}"

[ -z "${LOCATION}" ] && exitError "LOCATION not defined on OPC_WALLET in \"${v_opc_file}\"."
[ -z "${CREDENTIAL_ALIAS}" ] && exitError "CREDENTIAL_ALIAS not defined on OPC_WALLET in \"${v_opc_file}\"."

v_wallet_loc=$(sed 's/^file://' <<< "${LOCATION}")

[ ! -d "${v_wallet_loc}" ] && exitError "Folder \"${v_wallet_loc}\" not found readable."

[ ! -r "${v_wallet_loc}/cwallet.sso" ] && exitError "File \"${v_wallet_loc}/cwallet.sso\" not found readable."

v_mkstore_out=$(${v_mkstore} -wrl "${v_wallet_loc}" -list -nologo) && v_ret=$? || v_ret=$?
if [ $v_ret -ne 0 ]
then
  exitError "\"${v_mkstore} -wrl "${v_wallet_loc}" -list -nologo\" failed! Ret: $v_ret"
fi

for v_entry in $(grep 'connect_string' <<< "${v_mkstore_out}")
do
  v_value=$(${v_mkstore} -wrl "${v_wallet_loc}" -viewEntry "${v_entry}" -nologo)
  if [[ "$v_value" = *" = ${CREDENTIAL_ALIAS}" ]]
  then
    v_entry_num=$(grep -E -o '[0-9]+ =' <<< "$v_value" | sed 's/ =//')
  fi
done

[ ! -z "${v_entry_num##*[!0-9]*}" ] || exitError "Could not find \"${CREDENTIAL_ALIAS}\" entry on \"${v_wallet_loc}\"."

v_user_entry="oracle.security.client.username${v_entry_num}"
v_pass_entry="oracle.security.client.password${v_entry_num}"

v_user=$(${v_mkstore} -wrl "${v_wallet_loc}" -viewEntry "${v_user_entry}" -nologo | sed "s/^${v_user_entry} = //")
v_pass=$(${v_mkstore} -wrl "${v_wallet_loc}" -viewEntry "${v_pass_entry}" -nologo | sed "s/^${v_pass_entry} = //")

v_curl_out=$(curl -s --user "${v_user}:${v_pass}" ${OPC_HOST}/${OPC_CONTAINER}/)

v_bytes=$(grep -E -o '"bytes":[0-9]+' <<< "${v_curl_out}" | sed 's/"bytes"://' | paste -sd+ | bc)

echo "${v_bytes}"

exit 0