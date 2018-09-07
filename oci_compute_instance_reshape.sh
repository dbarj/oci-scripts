#!/bin/bash
#************************************************************************
#
#   oci_compute_instance_reshape.sh - Change Shape of Compute Instance
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
# Version 1.04
#************************************************************************
set -e

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

if [ $# -ne 2 ]
then
  echoError "$0: Two arguments are needed.. given: $#"
  echoError "- 1st param = Compute Instance Name or OCID"
  echoError "- 2nd param = Compute Instance Target Shape"
  exit 1
fi

v_inst_name="$1"
v_new_shape="$2"

[ -n "$v_inst_name" ] || exitError "Intance Name or OCID can't be null."
[ -n "$v_new_shape" ] || exitError "Shape can't be null."

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

v_test=$(${v_oci} iam compartment list --all 2>&1) && ret=$? || ret=$?
if [ $ret -ne 0 ]
then
  echoError "oci-cli not able to run \"${v_oci} iam compartment list --all\". Please check error:"
  echoError "$v_test"
  exit 1
fi

if [ "${v_inst_name:0:18}" == "ocid1.instance.oc1" ]
then
  v_instanceID=$(${v_oci} compute instance get --instance-id "${v_inst_name}" | ${v_jq} -rc '.data | select(."lifecycle-state" != "TERMINATED") | ."id"') && ret=$? || ret=$?
  if [ $ret -ne 0 -o -z "$v_instanceID" ]
  then
    exitError "Could not find a compute with the provided OCID."
  fi
  v_inst_name=$(${v_oci} compute instance get --instance-id "${v_instanceID}" | ${v_jq} -rc '.data."display-name"') && ret=$? || ret=$?
  if [ $ret -ne 0 -o -z "$v_inst_name" ]
  then
    exitError "Could not get Display Name of compute ${v_instanceID}"
  fi
else
  l_comps=$(${v_oci} iam compartment list --all | ${v_jq} -rc '.data[]."id"') && ret=$? || ret=$?
  if [ $ret -ne 0 -o -z "$l_comps" ]
  then
    exitError "Could not list Compartments."
  fi
  for v_comp in $l_comps
  do
    v_out=$(${v_oci} compute instance list --compartment-id "$v_comp" --all | ${v_jq} -rc '.data[] | select(."display-name" == "'"${v_inst_name}"'" and ."lifecycle-state" != "TERMINATED") | ."id"') && ret=$? || ret=$?
    [ $ret -eq 0 ] || exitError "Could not search the OCID of compute ${v_inst_name} in compartment ${v_comp}. Use OCID instead."
    if [ -n "$v_out" ]
    then
      [ -z "$v_instanceID" ] || exitError "More than 1 compute named \"${v_inst_name}\" found in this Tenancy. Use OCID instead."
      [ -n "$v_instanceID" ] || v_instanceID="$v_out"
    fi
  done
  if [ -z "$v_instanceID" ]
  then
    exitError "Could not get OCID of compute ${v_inst_name}"
  elif [ $(echo "$v_instanceID" | wc -l) -ne 1 ]
  then
    exitError "More than 1 compute named \"${v_inst_name}\" found in one Compartment. Use OCID instead."
  fi
fi

v_compartment_id=$(${v_oci} compute instance get --instance-id "${v_instanceID}" | ${v_jq} -rc '.data."compartment-id"') && ret=$? || ret=$?
if [ $ret -ne 0 -o -z "$v_compartment_id" ]
then
  exitError "Could not get the instance Compartment ID."
fi
v_compartment_arg="--compartment-id ${v_compartment_id}"

v_jsoninst=$(${v_oci} compute instance get --instance-id "${v_instanceID}" | ${v_jq} -rc '.data') && ret=$? || ret=$?
if [ $ret -ne 0 -o -z "$v_jsoninst" ]
then
  exitError "Could not get Json for compute ${v_inst_name}"
fi

v_jsonvnics=$(${v_oci} compute instance list-vnics --all --instance-id "${v_instanceID}" | ${v_jq} -rc '.data[]') && ret=$? || ret=$?
if [ $ret -ne 0 -o -z "$v_jsonvnics" ]
then
  exitError "Could not get Json for vnics of ${v_inst_name}"
fi

v_jsonprivnic=$(echo "$v_jsonvnics" | ${v_jq} -rc 'select (."is-primary" == true)')
v_jsonsecvnic=$(echo "$v_jsonvnics" | ${v_jq} -rc 'select (."is-primary" != true)')

v_jsonpubsip=$(${v_oci} network public-ip list ${v_compartment_arg} --scope REGION --all | ${v_jq} -rc '.data[]') && ret=$? || ret=$?
if [ $ret -ne 0 ]
then
  exitError "Could not get Json for Public IPs of ${v_inst_name}"
fi
v_reservedpubsip=$(echo "$v_jsonpubsip" | ${v_jq} -rc '."ip-address"')

v_instanceAD=$(echo "$v_jsoninst" | ${v_jq} -rc '."availability-domain"')
[ -n "$v_instanceAD" ] || exitError "Could not get Instance Availability Domain."

v_shapecheck=$(${v_oci} compute shape list ${v_compartment_arg} --all --availability-domain "$v_instanceAD" | ${v_jq} -rc '.data[] | select (."shape" == "'$v_new_shape'") | ."shape"')
[ "$v_shapecheck" == "$v_new_shape" ] || exitError "Shape \"$v_new_shape\" not found in this AD."

v_instanceShape=$(echo "$v_jsoninst" | ${v_jq} -rc '."shape"')
[ -n "$v_instanceShape" ] || exitError "Could not get Instance Shape."
[ "$v_instanceShape" != "$v_new_shape" ] || exitError "Source and Target shapes are the same."

v_instancePriVnicIP=$(echo "$v_jsonprivnic" | ${v_jq} -rc '."private-ip"')
[ -n "$v_instancePriVnicIP" ] || exitError "Could not get Instance Primary Private IP Address."

v_instancePriVnicSubnetID=$(echo "$v_jsonprivnic" | ${v_jq} -rc '."subnet-id"')
[ -n "$v_instancePriVnicSubnetID" ] || exitError "Could not get Instance Primary Subnet ID."

v_instanceBVID=$(${v_oci} compute boot-volume-attachment list ${v_compartment_arg} --availability-domain "${v_instanceAD}" --instance-id "${v_instanceID}" | ${v_jq} -rc '.data[] | ."boot-volume-id"')
[ -n "$v_instanceBVID" ] || exitError "Could not get Instance Boot Volume ID."

echo "Machine will be moved from \"$v_instanceShape\" to \"$v_new_shape\"."

v_extra_vnic_params=""
# --defined-tags
v_out=$(echo "$v_jsonprivnic" | ${v_jq} -rc '."defined-tags"' | sed "s/'/'\\\''/g")
[ -z "$v_out" -o "$v_out" == "{}" ] || v_extra_vnic_params="${v_extra_vnic_params}--defined-tags '$v_out' \\"$'\n'
# --freeform-tags
v_out=$(echo "$v_jsonprivnic" | ${v_jq} -rc '."freeform-tags"' | sed "s/'/'\\\''/g")
[ -z "$v_out" -o "$v_out" == "{}" ] || v_extra_vnic_params="${v_extra_vnic_params}--freeform-tags '$v_out' \\"$'\n'

v_extra_inst_params=""
# --vnic-display-name
v_out=$(echo "$v_jsonprivnic" | ${v_jq} -rc '."display-name"' | sed "s/'/'\\\''/g")
[ -z "$v_out" ] || v_extra_inst_params="${v_extra_inst_params}--vnic-display-name '$v_out' \\"$'\n'
# --hostname-label
v_out=$(echo "$v_jsonprivnic" | ${v_jq} -rc '."hostname-label"' | sed "s/'/'\\\''/g")
[ -z "$v_out" ] || v_extra_inst_params="${v_extra_inst_params}--hostname-label '$v_out' \\"$'\n'
# --skip-source-dest-check
v_out=$(echo "$v_jsonprivnic" | ${v_jq} -rc '."skip-source-dest-check"' | sed "s/'/'\\\''/g")
[ -z "$v_out" ] || v_extra_inst_params="${v_extra_inst_params}--skip-source-dest-check '$v_out' \\"$'\n'
# --assign-public-ip
v_out=$(echo "$v_jsonprivnic" | ${v_jq} -rc '."public-ip" // empty' | sed "s/'/'\\\''/g")
if [ -n "$v_out" ]
then
  if grep -q -F -x "$v_out" <(echo "$v_reservedpubsip")
  then
    v_extra_inst_params="${v_extra_inst_params}--assign-public-ip false \\"$'\n'
  else
    v_extra_inst_params="${v_extra_inst_params}--assign-public-ip true \\"$'\n'
  fi
else
  v_extra_inst_params="${v_extra_inst_params}--assign-public-ip false \\"$'\n'
fi
v_instancePriVnicPubIP="$v_out"
# --defined-tags
v_out=$(echo "$v_jsoninst" | ${v_jq} -rc '."defined-tags"' | sed "s/'/'\\\''/g")
[ -z "$v_out" ] || v_extra_inst_params="${v_extra_inst_params}--defined-tags '$v_out' \\"$'\n'
# --freeform-tags
v_out=$(echo "$v_jsoninst" | ${v_jq} -rc '."freeform-tags"' | sed "s/'/'\\\''/g")
[ -z "$v_out" ] || v_extra_inst_params="${v_extra_inst_params}--freeform-tags '$v_out' \\"$'\n'
# --metadata
v_out=$(echo "$v_jsoninst" | ${v_jq} -rc '."metadata"' | sed "s/'/'\\\''/g")
[ -z "$v_out" ] || v_extra_inst_params="${v_extra_inst_params}--metadata '$v_out' \\"$'\n'
# --extended-metadata
v_out=$(echo "$v_jsoninst" | ${v_jq} -rc '."extended-metadata"' | sed "s/'/'\\\''/g")
[ -z "$v_out" ] || v_extra_inst_params="${v_extra_inst_params}--extended-metadata '$v_out' \\"$'\n'
# --fault-domain
v_out=$(echo "$v_jsoninst" | ${v_jq} -rc '."fault-domain"' | sed "s/'/'\\\''/g")
[ -z "$v_out" ] || v_extra_inst_params="${v_extra_inst_params}--fault-domain '$v_out' \\"$'\n'
# --ipxe-script-file
v_out=$(echo "$v_jsoninst" | ${v_jq} -rc '."ipxe-script" // empty' | sed "s/'/'\\\''/g")
[ -z "$v_out" ] || v_extra_inst_params="${v_extra_inst_params}--ipxe-script-file '$v_out' \\"$'\n'

## List Vols

f_jsonvols=$(${v_oci} compute volume-attachment list ${v_compartment_arg} --all --instance-id "${v_instanceID}" | ${v_jq} -r '.data[] | select(."lifecycle-state" == "ATTACHED")')

## Save Files - Just for backup.

mkdir ${v_instanceID} && ret=$? || ret=$?
if [ $ret -ne 0 ]
then
  exitError "Could not create execution folder. Check if previous run is incompleted or files permissions."
fi
[ -f ${v_instanceID}/inst.json  ] || echo "$v_jsoninst"  > ${v_instanceID}/inst.json
[ -f ${v_instanceID}/vnics.json ] || echo "$v_jsonvnics" > ${v_instanceID}/vnics.json
[ -f ${v_instanceID}/vols.json  ] || echo "$f_jsonvols"  > ${v_instanceID}/vols.json

v_runall=${v_instanceID}/runall.sh

## Stop Machine

cat >> "$v_runall" <<EOF
cd "${v_instanceID}"
# Stop Instance
${v_oci} compute instance action \\
--instance-id '${v_instanceID}' \\
--action SOFTSTOP \\
--wait-for-state STOPPED \\
--max-wait-seconds $v_ocicli_timeout \\
>> runall.log
ret=\$?
EOF

## Drop Machine

cat >> "$v_runall" <<EOF
# Terminate Instance
${v_oci} compute instance terminate \\
--force \\
--instance-id '${v_instanceID}' \\
--wait-for-state TERMINATED \\
--preserve-boot-volume true \\
--max-wait-seconds $v_ocicli_timeout \\
>> runall.log
ret=\$?
EOF

## Create New Machine

cat >> "$v_runall" <<EOF
# Create Instance
${v_oci} compute instance launch ${v_compartment_arg} \\
--availability-domain '${v_instanceAD}' \\
--shape '${v_new_shape}' \\
--display-name '${v_inst_name}' \\
--source-boot-volume-id '${v_instanceBVID}' \\
--subnet-id '${v_instancePriVnicSubnetID}' \\
--private-ip '${v_instancePriVnicIP}' \\
--wait-for-state RUNNING \\
--max-wait-seconds $v_ocicli_timeout \\
${v_extra_inst_params}>> instance.log
ret=\$?
cat instance.log >> runall.log
EOF

## New Instance ID

cat >> "$v_runall" <<EOF
# Define new vars
v_newInstanceID=\$(cat instance.log | ${v_jq} -rc '.data."id"')
v_newInstancePriVnicID=\$(${v_oci} compute instance list-vnics --all --instance-id "\${v_newInstanceID}" | ${v_jq} -rc '.data[] | select (."is-primary" == true) | ."id"')
EOF

## Update Primary VNIC

if [ -n "${v_extra_vnic_params}" ]
then
  cat >> "$v_runall" <<EOF
# Primary VNIC update
${v_oci} network vnic update \\
--force \\
--vnic-id "\${v_newInstancePriVnicID}" \\
${v_extra_vnic_params}>> runall.log
ret=\$?
EOF
fi

## Assign reserved Pub IP to Primary VNIC

if [ -n "$v_instancePriVnicPubIP" ]
then
  if grep -q -F -x "$v_instancePriVnicPubIP" <(echo "$v_reservedpubsip")
  then
    v_publicipid=$(echo "$v_jsonpubsip" | ${v_jq} -rc 'select(."ip-address" == "'"$v_instancePriVnicPubIP"'") | ."id"')
    cat >> "$v_runall" <<EOF
# Primary VNIC assign Public IP
v_privateipid=\$(${v_oci} network private-ip list --all --ip-address "$v_instancePriVnicIP" --subnet-id "${v_instancePriVnicSubnetID}" | ${v_jq} -rc '.data[]."id"')
${v_oci} network public-ip update \\
--public-ip-id '${v_publicipid}' \\
--private-ip-id "\${v_privateipid}" \\
--wait-for-state ASSIGNED \\
--max-wait-seconds $v_ocicli_timeout \\
>> runall.log
ret=\$?
EOF
  fi
fi

## Create Aditional VNICs

f_instvnics=$(echo "$v_jsonsecvnic" | ${v_jq} -rc '."id"')
for v_instvnics in $f_instvnics
do
  v_1=$(echo "$v_jsonsecvnic" | ${v_jq} -rc 'select (."id" == "'${v_instvnics}'") | ."subnet-id"' | sed "s/'/'\\\''/g")
  v_2=$(echo "$v_jsonsecvnic" | ${v_jq} -rc 'select (."id" == "'${v_instvnics}'") | ."display-name"' | sed "s/'/'\\\''/g")
  v_3=$(echo "$v_jsonsecvnic" | ${v_jq} -rc 'select (."id" == "'${v_instvnics}'") | ."freeform-tags"' | sed "s/'/'\\\''/g")
  v_4=$(echo "$v_jsonsecvnic" | ${v_jq} -rc 'select (."id" == "'${v_instvnics}'") | ."hostname-label" // empty' | sed "s/'/'\\\''/g")
  v_5=$(echo "$v_jsonsecvnic" | ${v_jq} -rc 'select (."id" == "'${v_instvnics}'") | ."private-ip"' | sed "s/'/'\\\''/g")
  v_6=$(echo "$v_jsonsecvnic" | ${v_jq} -rc 'select (."id" == "'${v_instvnics}'") | ."public-ip" // empty' | sed "s/'/'\\\''/g")
  v_7=$(echo "$v_jsonsecvnic" | ${v_jq} -rc 'select (."id" == "'${v_instvnics}'") | ."skip-source-dest-check"' | sed "s/'/'\\\''/g")
  v_8=$(echo "$v_jsonsecvnic" | ${v_jq} -rc 'select (."id" == "'${v_instvnics}'") | ."defined-tags"' | sed "s/'/'\\\''/g")
  v_extra_vnic_params=""
  [ -z "$v_1" ] || v_extra_vnic_params="${v_extra_vnic_params}--subnet-id '$v_1' \\"$'\n'
  [ -z "$v_2" ] || v_extra_vnic_params="${v_extra_vnic_params}--vnic-display-name '$v_2' \\"$'\n'
  [ -z "$v_3" ] || v_extra_vnic_params="${v_extra_vnic_params}--freeform-tags '$v_3' \\"$'\n'
  [ -z "$v_4" ] || v_extra_vnic_params="${v_extra_vnic_params}--hostname-label '$v_4' \\"$'\n'
  [ -z "$v_5" ] || v_extra_vnic_params="${v_extra_vnic_params}--private-ip '$v_5' \\"$'\n'
  if [ -n "$v_6" ]
  then
    if grep -q -F -x "$v_6" <(echo "$v_reservedpubsip")
    then
      v_extra_inst_params="${v_extra_inst_params}--assign-public-ip false \\"$'\n'
    else
      v_extra_inst_params="${v_extra_inst_params}--assign-public-ip true \\"$'\n'
    fi
  else
    v_extra_inst_params="${v_extra_inst_params}--assign-public-ip false \\"$'\n'
  fi
  [ -z "$v_7" ] || v_extra_vnic_params="${v_extra_vnic_params}--skip-source-dest-check '$v_7' \\"$'\n'
  [ -z "$v_8" ] || v_extra_vnic_params="${v_extra_vnic_params}--defined-tags '$v_8' \\"$'\n'
  cat >> "$v_runall" <<EOF
# Add VNIC
${v_oci} compute instance attach-vnic \\
--instance-id "\${v_newInstanceID}" \\
--wait \\
${v_extra_vnic_params}>> runall.log
ret=\$?
EOF
  if [ -n "$v_6" ]
  then
    if grep -q -F -x "$v_6" <(echo "$v_reservedpubsip")
    then
      v_publicipid=$(echo "$v_jsonpubsip" | ${v_jq} -rc 'select(."ip-address" == "'"$v_6"'") | ."id"')
      cat >> "$v_runall" <<EOF
# Secondary VNIC assign Public IP
v_privateipid=\$(${v_oci} network private-ip list --all --ip-address "$v_5" --subnet-id "$v_1" | ${v_jq} -rc '.data[]."id"')
${v_oci} network public-ip update \\
--public-ip-id '${v_publicipid}' \\
--private-ip-id "\${v_privateipid}" \\
--wait-for-state ASSIGNED \\
--max-wait-seconds $v_ocicli_timeout \\
>> runall.log
ret=\$?
EOF
    fi
  fi
done

## Attach Vols

f_instvols=$(echo "$f_jsonvols" | ${v_jq} -rc '."id"')

for v_instvols in $f_instvols
do
  v_volid=$(echo "$f_jsonvols" | ${v_jq} -rc 'select (."id" == "'${v_instvols}'") | ."volume-id"' | sed "s/'/'\\\''/g")
  v_volro=$(echo "$f_jsonvols" | ${v_jq} -rc 'select (."id" == "'${v_instvols}'") | ."is-read-only"' | sed "s/'/'\\\''/g")
  v_voltype=$(echo "$f_jsonvols" | ${v_jq} -rc 'select (."id" == "'${v_instvols}'") | ."attachment-type"' | sed "s/'/'\\\''/g")
  cat >> "$v_runall" <<EOF
# Attach Volume
${v_oci} compute volume-attachment attach \\
--instance-id "\${v_newInstanceID}" \\
--type '${v_voltype}' \\
--volume-id '${v_volid}' \\
--is-read-only '${v_volro}' \\
--wait-for-state ATTACHED \\
--max-wait-seconds $v_ocicli_timeout \\
>> runall.log
ret=\$?
EOF
done

## List Steps

echo "Following steps will be executed:"
echo "- Instance \"${v_inst_name}\"(${v_instanceID}) will be stopped."
echo "- Instance \"${v_inst_name}\"(${v_instanceID}) will be terminated."
echo "- New instance \"${v_inst_name}\" will be created with same boot volume and attributes (new OCID generated)."
[ -z "$v_extra_vnic_params" ] || echo "- Primary VNIC on new instance \"${v_inst_name}\" will be updated."
[ -z "$v_jsonsecvnic" ] || echo "- Secondary VNICs will be reattach."
[ -z "$f_jsonvols" ]    || echo "- Block Volumes will be reattach."
echo "Execution script created at \"$v_runall\" file."
echo -n "Type \"YES\" to execute it and apply the changes: "
read v_input
[ "$v_input" == "YES" ] || exitError "Script aborted."

## Public IP Notice

v_out=$(echo "$v_jsonvnics" | ${v_jq} -rc '."public-ip" // empty')
if [ -n "$v_out" ]
then
  v_ephemeralips=$(comm -2 -3 <(sort <(echo "$v_out")) <(sort <(echo "$v_reservedpubsip")))
  if [ -n "$v_ephemeralips" ]
  then
    echo "This instance has some VNICs with Ephemeral Public IPs assigned: $(echo "$v_ephemeralips" | tr "\n" "," | sed 's/,$//')."
    echo "Note that recreating the Machine will reassign a different Public IP."
    echo -n "Type \"YES\" to continue: "
    read v_input
    [ "$v_input" == "YES" ] || exitError "Script aborted."
  fi
fi

## Run Script:

set -x
. "$v_runall"
cd -
set +x

echo "MACHINE RECREATED SUCCESSFULLY"

## ISCSI Vols

[ -z "$f_jsonvols" ] || tempshell=${v_instanceID}/tempshell.sh
[ -z "$f_jsonvols" ] || echo "set -x" > "$tempshell"

for v_instvols in $f_instvols
do
  v_iqn=$(echo "$f_jsonvols" | ${v_jq} -rc 'select (."id" == "'${v_instvols}'") | ."iqn"')
  v_ipv4=$(echo "$f_jsonvols" | ${v_jq} -rc 'select (."id" == "'${v_instvols}'") | ."ipv4"')
  v_port=$(echo "$f_jsonvols" | ${v_jq} -rc 'select (."id" == "'${v_instvols}'") | ."port"')
  echo "sudo iscsiadm -m node -T ${v_iqn} -p ${v_ipv4}:${v_port} -u" >> "$tempshell"
  echo "sudo iscsiadm -m node -o delete -T ${v_iqn} -p ${v_ipv4}:${v_port}" >> "$tempshell"
done

f_jsonvols=$(${v_oci} compute volume-attachment list ${v_compartment_arg} --all --instance-id "${v_newInstanceID}" | ${v_jq} -r '.data[] | select(."lifecycle-state" == "ATTACHED")')
f_instvols=$(echo "$f_jsonvols" | ${v_jq} -rc '."id"')

for v_instvols in $f_instvols
do
  v_iqn=$(echo "$f_jsonvols" | ${v_jq} -rc 'select (."id" == "'${v_instvols}'") | ."iqn"')
  v_ipv4=$(echo "$f_jsonvols" | ${v_jq} -rc 'select (."id" == "'${v_instvols}'") | ."ipv4"')
  v_port=$(echo "$f_jsonvols" | ${v_jq} -rc 'select (."id" == "'${v_instvols}'") | ."port"')
  echo "sudo iscsiadm -m node -o new -T ${v_iqn} -p ${v_ipv4}:${v_port}" >> "$tempshell"
  echo "sudo iscsiadm -m node -o update -T ${v_iqn} -n node.startup -v automatic" >> "$tempshell"
  echo "sudo iscsiadm -m node -T ${v_iqn} -p ${v_ipv4}:${v_port} -l" >> "$tempshell"
done

## Ask if reconfig using SSH

if [ -s "$tempshell" ]
then
  echo "set +x" >> "$tempshell"
  echo "#### BEGIN - NEW DISKS IPS DISCOVERY ####"
  cat "$tempshell"
  echo "####  END  - NEW DISKS IPS DISCOVERY ####"

  echo -n "Script above must be executed in target machine. Type \"YES\" to apply the changes via SSH: "
  read v_input
  if [ "$v_input" == "YES" ]
  then
    ## Wait SSH UP
    echo 'Checking Server availability..'
    v_total=40
    v_loop=1
    while [ ${v_loop} -le ${v_total} ]
    do
      timeout 5 bash -c "true &>/dev/null </dev/tcp/$v_instancePriVnicIP/22" && ret=$? || ret=$?
      [ $ret -eq 0 ] && v_loop=$((v_total+1)) && echo 'Server Available!' && sleep 5
      [ $ret -ne 0 ] && echo "Server Unreachable, please wait. Try ${v_loop} of ${v_total}." && v_loop=$((v_loop+1)) && sleep 10
    done

    ## Update Attachments
    ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no opc@${v_instancePriVnicIP} "bash -s" < "$tempshell"
    ret=$?

    ## Restart Machine
    echo 'Bouncing the instance..'
    set -x
    ${v_oci} compute instance action \
    --instance-id "${v_newInstanceID}" \
    --action SOFTRESET \
    --wait-for-state RUNNING \
    --max-wait-seconds $v_ocicli_timeout > ${v_instanceID}/tempshell.log
    set +x

  fi
fi

echo "SCRIPT EXECUTED SUCCESSFULLY"

exit 0
###