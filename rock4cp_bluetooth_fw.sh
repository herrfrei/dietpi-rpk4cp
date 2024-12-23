#!/bin/bash -eu
#
# Setup script for Rock 4 C+ board bluetooth firmware link
# Ensure that the root fs is mounted in read-write mode!


if [[ $EUID -ne 0 ]]; then
  echo >&2 "This program must be run with superuser rights"
  exit -1
fi

cd /lib/firmware/brcm && ln -s BCM4345C0_003.001.025.0162.0000_Generic_UART_37_4MHz_wlbga_ref_iLNA_iTR_eLG.hcd "BCM4345C0.radxa,rock-4c-plus.hcd"
