#!/bin/bash
#************************************************************************
#
#   oci_json_export.sh - Export all OCI information into JSON format
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
# Version 1.07
#************************************************************************
set -e

# Define paths for oci-cli and jq or put them on $PATH. Don't use relative PATHs in the variables below.
v_oci="oci"
v_jq="jq"

# Add any desired oci argument. Keep default to avoid oci_cli_rc usage.
v_oci_args="--cli-rc-file /dev/null"

# Don't change it.
v_min_ocicli="2.4.30"

# Temporary Folder. Used to stage some repetitive jsons and save time. Empty to disable.
v_tmpfldr="/tmp/oci"

[[ "${DEBUG}" == "" ]] && DEBUG=0

function echoError ()
{
   (>&2 echo "$1")
}

function funcCheckValueInRange ()
{
  [ "$#" -ne 2 ] && return 1
  local v_arg1="$1" # Value
  local v_arg2="$2" # Range
  [ -z "${v_arg1}" ] && return 1
  [ -z "${v_arg2}" ] && return 1
  local v_array=$(echo "${v_arg2}" | tr "," "\n")
  for v_opt in $v_array
  do
    if [ "$v_opt" == "${v_arg1}" ]
    then
      echo "Y"
      return 0
    fi
  done
  echo "N"
}

function funcPrintRange ()
{
  [ "$#" -ne 1 ] && return 1
  local v_arg1="$1" # Range
  [ -z "${v_arg1}" ] && return 1
  local v_array=$(echo "${v_arg1}" | tr "," "\n")
  for v_opt in $v_array
  do
    echo "- ${v_opt}"
  done
}

v_valid_opts="ALL,ALL_REGIONS"
v_func_list=$(sed -e '1,/^# BEGIN DYNFUNC/d' -e '/^# END DYNFUNC/,$d' -e 's/^# *//' $0)
v_opt_list=$(echo "${v_func_list}" | cut -d ',' -f 1 | sort | tr "\n" ",")
v_valid_opts="${v_valid_opts},${v_opt_list}"

v_param1="$1"
v_param2="$2"
v_param3="$3"

#[ -n "$v_param1" ] || v_param1="ALL"

v_check=$(funcCheckValueInRange "$v_param1" "$v_valid_opts") && ret=$? || ret=$?

if [ "$v_check" == "N" -o $ret -ne 0 ]
then
  echoError "Usage: $0 <option> [begin_time] [end_time]"
  echoError ""
  #echoError "<option> - Execution Scope. If ommited, \"ALL\" will be assumed."
  echoError "<option> - Execution Scope."
  echoError "[begin_time] (Optional) - Defines start time when exporting Audit Events."
  echoError "[end_time]   (Optional) - Defines end time when exporting Audit Events."
  echoError "* for more information about audit events param formats, run \"oci audit event list -h\"."
  echoError ""
  echoError "Valid <option> values are:"
  echoError "- ALL         - Execute json export for ALL possible options and compress output in a zip file."
  echoError "- ALL_REGIONS - Same as ALL, but run for all tenancy's subscribed regions."
  echoError "$(funcPrintRange "$v_opt_list")"
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
  echoError "Minimal oci version required is ${v_min_ocicli}. Found: ${v_cur_ocicli}"
  exit 1
fi

[ -z "${v_oci_args}" ] || v_oci="${v_oci} ${v_oci_args}"

v_test=$(${v_oci} iam region-subscription list 2>&1) && ret=$? || ret=$?
if [ $ret -ne 0 ]
then
  echoError "oci-cli not able to run \"${v_oci} iam region-subscription list\". Please check error:"
  echoError "$v_test"
  exit 1
fi

## Test if temp folder is writable
if [ -n "${v_tmpfldr}" ]
then
  mkdir "${v_tmpfldr}" 2>&- || true
else
  echoError "Temporary folder is DISABLED. Execution will take much longer."
  echoError "Press CTRL+C in next 10 seconds if you want to fix this."
  sleep 10
fi
if [ -n "${v_tmpfldr}" -a ! -w "${v_tmpfldr}" ]
then
  echoError "Temporary folder \"${v_tmpfldr}\" is NOT WRITABLE. Execution will take much longer."
  echoError "Press CTRL+C in next 10 seconds if you want to fix this."
  sleep 10
  v_tmpfldr=""
fi

################################################
############### CUSTOM FUNCTIONS ###############
################################################

function jsonShapes ()
{
  local v_fout=""
  v_fout=$(jsonAllCompartAddTag "compute shape list --all")
  ## Remove Duplicates
  [ -z "$v_fout" ] || v_fout=$(echo "${v_fout}" | ${v_jq} '.data | unique | {data : .}')
  [ -z "$v_fout" ] || echo "${v_fout}"
}

function jsonAudEvents ()
{
  [ "$#" -eq 1 -a "$1" != "" -a "$1" != " " ] || echoError "${FUNCNAME[0]} skipped. No parameter given."
  [ "$#" -eq 1 -a "$1" != "" -a "$1" != " " ] || return 1
  local v_arg1=$(echo "$1" | cut -d ' ' -f 1)
  local v_arg2=$(echo "$1" | cut -d ' ' -f 2)
  [ "$v_arg1" != "" -a "$v_arg2" != "" ] || echoError "${FUNCNAME[0]} skipped. Wrong parameter format."
  [ "$v_arg1" != "" -a "$v_arg2" != "" ] || return 1
  local v_out=$(jsonAllCompart "audit event list --all --start-time "$v_arg1" --end-time "$v_arg2"")
  [ -z "$v_out" ] || echo "${v_out}"
}

function jsonBkpPolAssign ()
{
  local v_out v_fout
  v_fout=$(jsonGenericMaster "bv volume-backup-policy-assignment get-volume-backup-policy-asset-assignment" "BV-Volumes" "id" "asset-id" "jsonSimple")
  v_out=$(jsonGenericMaster "bv volume-backup-policy-assignment get-volume-backup-policy-asset-assignment" "BV-BVolumes" "id" "asset-id" "jsonSimple")
  [ -z "$v_out" ] || v_fout=$(${v_jq} 'reduce inputs as $i (.; .data += $i.data)' <(echo "$v_fout") <(echo "$v_out"))
  [ -z "$v_fout" ] || echo "${v_fout}"
}

function jsonPublicIPs ()
{
  local v_out v_fout
  v_fout=$(jsonAllCompart "network public-ip list --scope REGION --all")
  v_out=$(jsonAllAD "network public-ip list --scope AVAILABILITY_DOMAIN --all")
  [ -z "$v_out" ] || v_fout=$(${v_jq} 'reduce inputs as $i (.; .data += $i.data)' <(echo "$v_fout") <(echo "$v_out"))
  [ -z "$v_fout" ] || echo "${v_fout}"
}

function jsonImages ()
{
  ## Get Images.
  local v_fout=$(jsonAllCompart "compute image list --all")
  ## Get also Images used By Instaces.
  local l_instImages=$(Comp-Instances | ${v_jq} -r '.data[]."image-id"' | sort -u)
  local l_images=$(echo "${v_fout}" | ${v_jq} -r '.data[]."id"')
  local l_diff=$(grep -F -x -v -f <(echo "$l_images") <(echo "$l_instImages"))
  for v_image in $l_diff
  do
    local v_out=$(jsonSimple "compute image get --image-id ${v_image}")
    [ -z "$v_out" ] || v_fout=$(${v_jq} 'reduce inputs as $i (.; .data += [$i.data])' <(echo "$v_fout") <(echo "$v_out"))
  done
  ## Get also Base Images of Images.
  local l_baseImages=$(echo "${v_fout}" | ${v_jq} -r '.data[] | select(."base-image-id" != null) | ."base-image-id"' | sort -u)
  local l_images=$(echo "${v_fout}" | ${v_jq} -r '.data[]."id"')
  local l_diff=$(grep -F -x -v -f <(echo "$l_images") <(echo "$l_baseImages"))
  for v_image in $l_diff
  do
    local v_out=$(jsonSimple "compute image get --image-id ${v_image}")
    [ -z "$v_out" ] || v_fout=$(${v_jq} 'reduce inputs as $i (.; .data += [$i.data])' <(echo "$v_fout") <(echo "$v_out"))
  done
  ## Remove Duplicates
  [ -z "$v_fout" ] || v_fout=$(echo "${v_fout}" | ${v_jq} '.data | unique | {data : .}')
  [ -z "$v_fout" ] || echo "${v_fout}"
}

################################################
############## GENERIC FUNCTIONS ###############
################################################

## jsonSimple        -> Simply run the parameter.
## jsonAllCompart    -> Run parameter for all container-ids.
## jsonAllCompartAdd -> Same as before, but also add container-id tag in json output.
## jsonAllAD         -> Run parameter for all availability-domains and container-ids.
## jsonAllVCN        -> Run parameter for all vcn-ids and container-ids.

function jsonSimple ()
{
  # Simply call oci-cli with all provided args in $1.
  [ "$#" -eq 1 -a "$1" != "" ] || echoError "${FUNCNAME[0]} needs 1 parameter"
  [ "$#" -eq 1 -a "$1" != "" ] || return 1
  local v_arg1="$1"
  (( $DEBUG )) && echo "$(date '+%Y%m%d%H%M%S'): ${v_oci} ${v_arg1}" >> debug.log
  local v_out=$(${v_oci} ${v_arg1})
  [ -z "$v_out" ] || echo "${v_out}"
}

function jsonAllCompart ()
{
  # Simply call oci-cli for all existent compartments.
  [ "$#" -eq 1 -a "$1" != "" ] || echoError "${FUNCNAME[0]} needs 1 parameter"
  [ "$#" -eq 1 -a "$1" != "" ] || return 1
  jsonGenericMaster "$1" "IAM-Comparts" "id" "compartment-id" "jsonSimple"
}

function jsonAllCompartAddTag ()
{
  # Call oci-cli for all existent compartments. In the end, add compartment-id tag to json output.
  [ "$#" -eq 1 -a "$1" != "" ] || echoError "${FUNCNAME[0]} needs 1 parameter"
  [ "$#" -eq 1 -a "$1" != "" ] || return 1
  jsonGenericMasterAdd "$1" "IAM-Comparts" "id" "compartment-id" "jsonSimple" "compartment-id"
}

function jsonAllAD ()
{
  # Call oci-cli for a combination of all existent Compartments x ADs..
  [ "$#" -eq 1 -a "$1" != "" ] || echoError "${FUNCNAME[0]} needs 1 parameter"
  [ "$#" -eq 1 -a "$1" != "" ] || return 1
  jsonGenericMaster "$1" "IAM-ADs" "name" "availability-domain" "jsonAllCompart"
}

function jsonAllVCN ()
{
  # Call oci-cli for all existent VCNs.
  [ "$#" -eq 1 -a "$1" != "" ] || echoError "${FUNCNAME[0]} needs 1 parameter"
  [ "$#" -eq 1 -a "$1" != "" ] || return 1
  jsonGenericMaster2 "$1" "Net-VCNs" "id" "vcn-id" "compartment-id" "compartment-id" "jsonSimple"
}

function jsonGenericMaster ()
{
  [ "$#" -eq 5 ] || echoError "${FUNCNAME[0]} needs 5 parameters"
  [ "$#" -eq 5 ] || return 1
  local v_arg1 v_arg2 v_arg3 v_arg4 v_arg5 v_out v_fout l_itens v_item
  v_arg1="$1" # Main oci call
  v_arg2="$2" # Subfunction 1 - FuncName
  v_arg3="$3" # Subfunction 1 - Tag to get
  v_arg4="$4" # Subfunction 1 - Param
  v_arg5="$5" # Subfunction 2 - FuncName
  v_fout=""
  l_itens=$(${v_arg2} | ${v_jq} -r '.data[]."'${v_arg3}'"')
  for v_item in $l_itens
  do
    v_out=$(${v_arg5} "${v_arg1} --${v_arg4} $v_item")
    [ -z "$v_out" ] || v_fout=$(${v_jq} 'reduce inputs as $i (.; .data += $i.data)' <(echo "$v_fout") <(echo "$v_out"))
  done
  [ -z "$v_fout" ] || echo "${v_fout}"
}

function jsonGenericMaster2 ()
{
  [ "$#" -eq 7 ] || echoError "${FUNCNAME[0]} needs 7 parameters"
  [ "$#" -eq 7 ] || return 1
  local v_arg1 v_arg2 v_arg3 v_arg4 v_arg5 v_arg6 v_arg7 v_out v_fout l_itens v_item v_item1 v_item2
  v_arg1="$1" # Main oci call
  v_arg2="$2" # Subfunction 1 - FuncName
  v_arg3="$3" # Subfunction 1 - Tag1 to get
  v_arg4="$4" # Subfunction 1 - Param1
  v_arg5="$5" # Subfunction 1 - Tag2 to get
  v_arg6="$6" # Subfunction 1 - Param2
  v_arg7="$7" # Subfunction 2 - FuncName
  v_fout=""
  v_item1=""
  l_itens=$(${v_arg2} | ${v_jq} -r '.data[] | ."'${v_arg3}'",."'${v_arg5}'"')
  for v_item in $l_itens
  do
    if [ -z "$v_item1" ]
    then
      v_item1="$v_item"
    else
      v_item2="$v_item"
      v_out=$(${v_arg7} "${v_arg1} --${v_arg4} $v_item1 --${v_arg6} $v_item2")
      [ -z "$v_out" ] || v_fout=$(${v_jq} 'reduce inputs as $i (.; .data += $i.data)' <(echo "$v_fout") <(echo "$v_out"))
      v_item1=""
    fi
  done
  [ -z "$v_fout" ] || echo "${v_fout}"
}

function jsonGenericMasterAdd ()
{
  [ "$#" -eq 6 ] || echoError "${FUNCNAME[0]} needs 6 parameters"
  [ "$#" -eq 6 ] || return 1
  local v_arg1 v_arg2 v_arg3 v_arg4 v_arg5 v_out v_fout l_itens v_item
  v_arg1="$1" # Main oci call
  v_arg2="$2" # Subfunction 1 - FuncName
  v_arg3="$3" # Subfunction 1 - Tag
  v_arg4="$4" # Subfunction 1 - Param
  v_arg5="$5" # Subfunction 2 - FuncName
  v_arg6="$6" # New Tag Name
  v_fout=""
  l_itens=$(${v_arg2} | ${v_jq} -r '.data[]."'${v_arg3}'"')
  for v_item in $l_itens
  do
    v_out=$(${v_arg5} "${v_arg1} --${v_arg4} $v_item")
    [ -z "$v_out" ] || v_out=$(echo "$v_out" | ${v_jq} '.data[] += {"'${v_arg6}'":"'"$v_item"'"}')
    [ -z "$v_out" ] || v_fout=$(${v_jq} 'reduce inputs as $i (.; .data += $i.data)' <(echo "$v_fout") <(echo "$v_out"))
  done
  [ -z "$v_fout" ] || echo "${v_fout}"
}

################################################
################# OPTION LIST ##################
################################################

# Structure:
# 1st - Json Function Name.
# 2nd - Json Target File Name. Used when ALL parameter is passed to the shell.
# 3rd - Function to call. Can be one off the generics above or a custom one.
# 4th - OCI command line to be executed.

# DON'T REMOVE/CHANGE THOSE COMMENTS. THEY ARE USED TO GENERATE DYNAMIC FUNCTIONS

# BEGIN DYNFUNC
# BV-BVBackups,oci_bv_boot-volume-backup.json,jsonAllCompart,"bv boot-volume-backup list --all"
# BV-BVolumes,oci_bv_boot-volume.json,jsonAllAD,"bv boot-volume list --all"
# BV-Backups,oci_bv_backup.json,jsonAllCompart,"bv backup list --all"
# BV-BkpPolicy,oci_bv_volume-backup-policy.json,jsonSimple,"bv volume-backup-policy list --all"
# BV-BkpPolicyAssign,oci_bv_volume-backup-policy-assignment.json,jsonBkpPolAssign
# BV-VolGroup,oci_bv_volume-group.json,jsonAllCompart,"bv volume-group list --all"
# BV-VolGroupBkp,oci_bv_volume-group-backup.json,jsonAllCompart,"bv volume-group-backup list --all"
# BV-Volumes,oci_bv_volume.json,jsonAllCompart,"bv volume list --all"
# Comp-BVAttachs,oci_compute_boot-volume-attachment.json,jsonAllAD,"compute boot-volume-attachment list --all"
# Comp-ConsConns,oci_compute_instance-console-connection.json,jsonAllCompart,"compute instance-console-connection list --all"
# Comp-Images,oci_compute_image.json,jsonImages
# Comp-Instances,oci_compute_instance.json,jsonAllCompart,"compute instance list --all"
# Comp-Shapes,oci_compute_shape.json,jsonShapes
# Comp-VnicAttachs,oci_compute_vnic-attachment.json,jsonAllCompart,"compute vnic-attachment list --all"
# Comp-VolAttachs,oci_compute_volume-attachment.json,jsonAllCompart,"compute volume-attachment list --all"
# DB-AutDB,oci_db_autonomous-database.json,jsonAllCompart,"db autonomous-database list --all"
# DB-AutDBBkp,oci_db_autonomous-database-backup.json,jsonAllCompart,"db autonomous-database-backup list --all"
# DB-AutDW,oci_db_autonomous-data-warehouse.json,jsonAllCompart,"db autonomous-data-warehouse list --all"
# DB-AutDWBkp,oci_db_autonomous-data-warehouse-backup.json,jsonAllCompart,"db autonomous-data-warehouse-backup list --all"
# DB-Backup,oci_db_backup.json,jsonAllCompart,"db backup list --all"
# DB-DGAssoc,oci_db_data-guard-association.json,jsonGenericMaster,"db data-guard-association list --all" "DB-Database" "id" "database-id" "jsonSimple"
# DB-Database,oci_db_database.json,jsonGenericMaster2,"db database list" "DB-System" "id" "db-system-id" "compartment-id" "compartment-id" "jsonSimple"
# DB-Nodes,oci_db_node.json,jsonGenericMaster2,"db node list --all" "DB-System" "id" "db-system-id" "compartment-id" "compartment-id" "jsonSimple"
# DB-Patch-ByDB,oci_db_patch_by-database.json,jsonGenericMaster,"db patch list by-database" "DB-Database" "id" "database-id" "jsonSimple"
# DB-Patch-ByDS,oci_db_patch_by-db-system.json,jsonGenericMaster,"db patch list by-db-system" "DB-System" "id" "db-system-id" "jsonSimple"
# DB-PatchHist-ByDB,oci_db_patch-history_by-database.json,jsonGenericMaster,"db patch-history list by-database" "DB-Database" "id" "database-id" "jsonSimple"
# DB-PatchHist-ByDS,oci_db_patch-history_by-db-system.json,jsonGenericMaster,"db patch-history list by-db-system" "DB-System" "id" "db-system-id" "jsonSimple"
# DB-System,oci_db_system.json,jsonAllCompart,"db system list --all"
# DB-SystemShape,oci_db_system-shape.json,jsonGenericMasterAdd,"db system-shape list --all" "IAM-ADs" "name" "availability-domain" "jsonAllCompartAddTag" "availability-domain"
# DB-Version,oci_db_version.json,jsonAllCompartAddTag,"db version list --all"
# IAM-ADs,oci_iam_availability-domain.json,jsonSimple,"iam availability-domain list"
# IAM-Comparts,oci_iam_compartment.json,jsonSimple,"iam compartment list --all"
# IAM-Regions,oci_iam_region-subscription.json,jsonSimple,"iam region-subscription list"
# Net-Cpe,oci_network_cpe.json,jsonAllCompart,"network cpe list --all"
# Net-CrossConn,oci_network_cross-connect.json,jsonAllCompart,"network cross-connect list --all"
# Net-CrossConnGrp,oci_network_cross-connect-group.json,jsonAllCompart,"network cross-connect-group list --all"
# Net-CrossConnLoc,oci_network_cross-connect-location.json,jsonAllCompart,"network cross-connect-location list --all"
# Net-CrossConnPort,oci_network_cross-connect-port-speed-shape.json,jsonAllCompart,"network cross-connect-port-speed-shape list --all"
# Net-DhcpOptions,oci_network_dhcp-options.json,jsonAllVCN,"network dhcp-options list --all"
# Net-DrgAttachs,oci_network_drg-attachment.json,jsonAllCompart,"network drg-attachment list --all"
# Net-Drgs,oci_network_drg.json,jsonAllCompart,"network drg list --all"
# Net-FCProviderServices,oci_network_fast-connect-provider-service.json,jsonSimple,"network fast-connect-provider-service list --compartment-id xxx --all"
# Net-InternetGateway,oci_network_internet-gateway.json,jsonAllVCN,"network internet-gateway list --all"
# Net-IpSecConns,oci_network_ip-sec-connection.json,jsonAllCompart,"network ip-sec-connection list --all"
# Net-LocalPeering,oci_network_local-peering-gateway.json,jsonAllVCN,"network local-peering-gateway list --all"
# Net-NetServiceGW,oci_network_service-gateway.json,jsonAllCompart,"network service-gateway list --all"
# Net-NetServices,oci_network_service.json,jsonSimple,"network service list --all"
# Net-PrivateIPs,oci_network_private-ip.json,jsonGenericMaster,"network private-ip list --all" "Net-Subnets" "id" "subnet-id" "jsonSimple"
# Net-PublicIPs,oci_network_public-ip.json,jsonPublicIPs
# Net-RemotePeering,oci_network_remote-peering-connection.json,jsonAllCompart,"network remote-peering-connection list --all"
# Net-RouteTables,oci_network_route-table.json,jsonAllVCN,"network route-table list --all"
# Net-SecLists,oci_network_security-list.json,jsonAllVCN,"network security-list list --all"
# Net-Subnets,oci_network_subnet.json,jsonAllVCN,"network subnet list --all"
# Net-VCNs,oci_network_vcn.json,jsonAllCompart,"network vcn list --all"
# Net-VirtCirc,oci_network_virtual-circuit.json,jsonAllCompart,"network virtual-circuit list --all"
# Net-VirtCircPubPref,oci_network_virtual-circuit-public-prefix.json,jsonGenericMaster,"network virtual-circuit-public-prefix list" "Net-VirtCirc" "id" "virtual-circuit-id" "jsonSimple"
# OS-Buckets,oci_os_bucket.json,jsonAllCompart,"os bucket list --all"
# OS-Multipart,oci_os_multipart.json,jsonGenericMasterAdd,"os multipart list --all" "OS-Buckets" "name" "bucket-name" "jsonSimple" "bucket-name"
# OS-Nameserver,oci_os_ns.json,jsonSimple,"os ns get"
# OS-NameserverMeta,oci_os_ns-metadata.json,jsonSimple,"os ns get-metadata"
# OS-Objects,oci_os_object.json,jsonGenericMasterAdd,"os object list --all" "OS-Buckets" "name" "bucket-name" "jsonSimple" "bucket-name"
# OS-PreauthReqs,oci_os_preauth-request.json,jsonGenericMasterAdd,"os preauth-request list --all" "OS-Buckets" "name" "bucket-name" "jsonSimple" "bucket-name"
# Search-ResTypes,oci_search_resource-type.json,jsonSimple,"search resource-type list --all"
# Audit-Events,oci_audit_event.json,jsonAudEvents,"$1"
# END DYNFUNC

# Using File Descriptor 3 to not interfere on "eval"
while read -u 3 -r c_line || [ -n "$c_line" ]
do
   c_name=$(echo "$c_line" | cut -d ',' -f 1)
   c_fname=$(echo "$c_line" | cut -d ',' -f 2)
   c_subfunc=$(echo "$c_line" | cut -d ',' -f 3)
   c_param=$(echo "$c_line" | cut -d ',' -f 4)
   [ -z "${v_tmpfldr}" ] || c_tmpfldr="| tee ${v_tmpfldr}/.${c_fname}"
   eval "${c_name}() { stopIfProcessed ${c_fname} || return 0; ${c_subfunc} ${c_param} ${c_tmpfldr}; }"
done 3< <(echo "$v_func_list")

stopIfProcessed ()
{
  # If function was executed before, print the output and stop.
  local v_arg1="$1"
  [ -n "${v_tmpfldr}" ] || return 0
  if [ -s "${v_tmpfldr}/.${v_arg1}" ]
  then
    cat "${v_tmpfldr}/.${v_arg1}"
    return 1
  else
    return 0
  fi
}

runAndZip ()
{
  [ "$#" -ge 2 ] || echoError "${FUNCNAME[0]} needs at least 2 parameters"
  [ "$#" -ge 2 ] || return 1
  local v_arg1="$1"
  local v_arg2="$2"
  local v_arg3="$3"
  [ "$v_arg1" != "" -a "$v_arg2" != "" ] || echoError "${FUNCNAME[0]} needs at least 2 parameters"
  [ "$v_arg1" != "" -a "$v_arg2" != "" ] || return 1
  echo "Processing \"${v_arg2}\"."
  ${v_arg1} "${v_arg3}" > "${v_arg2}" 2> "${v_arg2}.err" && ret=$? || ret=$?
  if [ -s "${v_arg2}.err" ]
  then
    echo "Skipped. Check \"${v_arg2}.err\" for more details."
    zip -qmT "$v_outfile" "${v_arg2}.err"
  elif [ -f "${v_arg2}.err" ]
  then
    rm -f "${v_arg2}.err"
  fi
  zip -qmT "$v_outfile" "${v_arg2}"
  echo "$v_arg2" >> "${v_listfile}"
}

cleanTmpFiles ()
{
  [ -z "${v_tmpfldr}" ] || rm -f "${v_tmpfldr}"/.*.json 2>&- || true
}

main ()
{
  cleanTmpFiles
  if [ "${v_param1}" != "ALL" -a "${v_param1}" != "ALL_REGIONS" ]
  then
    ${v_param1} "${v_param2} ${v_param3}"
  else
    [ -n "$v_outfile" ] || v_outfile="oci_json_export_$(date '+%Y%m%d%H%M%S').zip"
    v_listfile="oci_json_export_list.txt"
    rm -f "${v_listfile}"
    while read -u 3 -r c_line || [ -n "$c_line" ]
    do
       c_name=$(echo "$c_line" | cut -d ',' -f 1)
       c_file=$(echo "$c_line" | cut -d ',' -f 2)
       runAndZip $c_name $c_file "${v_param2} ${v_param3}"
    done 3< <(echo "$v_func_list")
    zip -qmT "$v_outfile" "${v_listfile}"
  fi
  cleanTmpFiles
}

if [ "${v_param1}" == "ALL_REGIONS" ]
then
  l_regions=$(IAM-Regions | ${v_jq} -r '.data[]."region-name"')
  v_oci_orig="$v_oci"
  v_outfile_pref="oci_json_export_$(date '+%Y%m%d%H%M%S')"
  for v_region in $l_regions
  do
    echo "Region ${v_region} set."
    v_oci="${v_oci_orig} --region ${v_region}"
    v_outfile="${v_outfile_pref}_${v_region}.zip"
    main
  done
else
  main
fi

[ -z "${v_tmpfldr}" ] || rmdir ${v_tmpfldr} 2>&- || true

exit 0
###