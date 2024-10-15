#! /usr/bin/env bash

FRCANARY_FLAG="/home/pi/.router/config/.no_upgrade_canary"
FRCANARY_FORCE="/home/pi/.router/config/.force_upgrade_canary"
FRCANARY_DEPLOY_RATIO="/home/pi/.router/config/.deploy_ratio"

rm -f $FRCANARY_FLAG
rm -f $FRCANARY_DEPLOY_RATIO

logger "FIREROUTER:UPGRADE_CANARY:START"

if [[ -e $FRCANARY_FORCE ]]; then
  echo "======= CANARY ALL UPGRADE BECAUSE OF FLAG $FRCANARY_FORCE ======="
  rm -f $FRCANARY_FORCE
  exit 0
fi

err() {
  echo "ERROR: $@" >&2
}

: ${FIREROUTER_HOME:=/home/pi/firerouter}
: ${FIREWALLA_HOME:=/home/pi/firewalla}
source ${FIREWALLA_HOME}/platform/platform.sh

[ -s ~/.fwrc ] && source ~/.fwrc
[ -s ${FIREWALLA_HOME}/scripts/network_settings.sh ] && source ${FIREWALLA_HOME}/scripts/network_settings.sh

: ${ASSETS_PREFIX:=$(get_assets_prefix)}
: ${RELEASE_TYPE:=$(get_release_type)}

## CANARY DEPLOYMENT RATIO CONFIG PATH
ASSETS_PREFIX=https://fireupgrade.s3.us-west-2.amazonaws.com/dev # TODO: DELETE ME
s3_ratio_path="${ASSETS_PREFIX}/canary/deploy_ratio"
cmd="wget -q -O ${FRCANARY_DEPLOY_RATIO} ${s3_ratio_path}"
eval $cmd

if [[ ! -e $FRCANARY_DEPLOY_RATIO ]];then
    err "ERROR: failed to get canary ratio"
    exit 1
fi

PHASED=$(cat $FRCANARY_DEPLOY_RATIO | jq .phased)
if [[ "$PHASED" != "true" ]];then
    echo "======= CANARY ALL UPGRADE BECAUSE OF FLAG PHASED $PHASED ======="
    exit 0
fi

cmd="cat $FRCANARY_DEPLOY_RATIO | jq 'try (."${FIREWALLA_PLATFORM}") // .default'"
echo $cmd
RATIO=$(eval $cmd)
if ! [[ $RATIO =~ ^[0-9]+$ ]] ; then
   err "ERROR: canary ratio is not a number"
   exit 1
fi

echo Canary ratio platform $FIREWALLA_PLATFORM: $RATIO

pushd ${FIREWALLA_HOME}
sudo chown -R pi ${FIREWALLA_HOME}/.git
fw_branch=$(git rev-parse --abbrev-ref HEAD)
fw_remote_branch=$(map_target_branch $fw_branch)
fw_local_hash=$(git rev-parse --short $fw_branch)
# fw_latest_hash=$(git rev-parse --short origin/$fw_remote_branch)
popd

pushd ${FIREROUTER_HOME}
sudo chown -R pi ${FIREROUTER_HOME}/.git
fr_branch=$(git rev-parse --abbrev-ref HEAD)
# fr_remote_branch=$(map_target_branch $fr_branch)
fr_local_hash=$(git rev-parse --short $fr_branch)
# fr_latest_hash=$(git rev-parse --short origin/$fr_remote_branch)
popd

## no update commits "firerouter"
cmd="cat $FRCANARY_DEPLOY_RATIO | jq -c '.no_update.firerouter.commits | index( \"'$fr_local_hash'\" )'"
index=$(eval $cmd)
if [[ "$index" != "null" && "$index" != "" ]];then
    echo "======= CANARY NO UPGRADE BECAUSE OF FLAG .no_update.firerouter.commits $fr_local_hash $index ======="
    echo $(date +%s) > ${FRCANARY_FLAG}
    exit 0
fi

## force update commits "firerouter"

cmd="cat $FRCANARY_DEPLOY_RATIO | jq -c '.force_update.firerouter.commits | index( \"'$fr_local_hash'\" )'"
index=$(eval $cmd)
if [[ "$index" != "null" && "$index" != "" ]];then
    echo "======= CANARY ALL UPGRADE BECAUSE OF FLAG .force_update.firerouter.commits $fr_local_hash $index ======="
    exit 0
fi

CONFIG_CMD="curl -s https://raw.githubusercontent.com/firewalla/firewalla/refs/heads/${fw_remote_branch}/net2/config.json | jq .version"
fw_remote_ver=$(eval $CONFIG_CMD)
if [[ "$fw_remote_ver" == "" ]];then
    err "ERROR: failed to get remote version"
    exit 1
fi

latest_ver="${fw_remote_ver}"
eidcmd="redis-cli hget sys:ept:me eid"
eid=$(eval $eidcmd)

md5hash=$(echo -n "${latest_ver}#${eid}" | md5sum | cut -d" " -f 1)
echo "md5: $md5hash (${latest_ver}#${eid})"

hash8=$(echo $md5hash | cut -c1-8 | tr '[:lower:]' '[:upper:]')
magic=$(echo "ibase=16; ${hash8}" | bc)
MAXVAL=$(echo $((16#FFFFFFFF)))
let "delta=${MAXVAL}*${RATIO}-100*${magic}"
if test $delta -ge 0
then
    echo "======= CANARY UPGRADING IN RATIO (${magic}) ======="
    echo "ratio $magic <= ${MAXVAL}*${RATIO}/100"
else
    echo "======= CANARY NO UPGRADING OUT OF RATIO (${magic}) ======="
    echo "ratio $magic > ${MAXVAL}*${RATIO}/100"
    echo $(date +%s) > ${FRCANARY_FLAG}
fi

logger "FIREROUTER:UPGRADE_CANARY:END"