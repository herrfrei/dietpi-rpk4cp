#!/bin/bash -eu
#
# Setup script for Rock 4 C+ board: install USB OTG peripheral mode device tree overlay

USER=${USER:-herrfrei}
REPO=${REPO:-dietpi-rock4cp}
BRANCH=${BRANCH:-main}

function download {
  SRC=$1
  DEST=$2
  echo "Downloading ${SRC}"
  while ! curl -s -S -o ${DEST} ${SRC} 
  do
    sleep 1
  done
}

function check_or_install_script {
  URL=$1
  SCRIPT_FILE=$(basename $1)
  if [ ! -x ${SCRIPT_FILE} ]
  then
    download ${URL} /boot/dietpi/${SCRIPT_FILE}
    chmod +x /boot/dietpi/${SCRIPT_FILE}
  fi
}

if [[ $EUID -ne 0 ]]; then
  echo >&2 "This program must be run with superuser rights"
  exit -1
fi

OVERLAY=rk3399-dwc3-0-peripheral
if grep -q '^user_overlays=' /boot/dietpiEnv.txt; then
  line=$(grep '^user_overlays=' /boot/dietpiEnv.txt | cut -d'=' -f2)
  if grep -qE "(^|[[:space:]])${OVERLAY}([[:space:]]|$)" <<< $line; then
    echo "Overlay ${OVERLAY} was already added to /boot/dietpiEnv.txt, skipping"
    exit 0
  fi
fi

# download and install USB OTG device tree file
DOWNLOAD_FILE=${OVERLAY}.dtbo
download https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${DOWNLOAD_FILE} ${DOWNLOAD_FILE}
check_or_install_script https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/dietpi-add-overlay
/boot/dietpi/dietpi-add-overlay ${DOWNLOAD_FILE}
rm -f ${DOWNLOAD_FILE}
