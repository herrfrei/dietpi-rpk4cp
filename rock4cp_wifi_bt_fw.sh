#!/bin/bash -eu
#
# Setup script for Rock 4 C+ board wifi / bluetooth firmware link
# Ensure that the root fs is mounted in read-write mode!


if [[ $EUID -ne 0 ]]; then
  echo >&2 "This program must be run with superuser rights"
  exit -1
fi

pushd /lib/firmware/brcm

[ -f BCM4345C0.radxa,rock-4c-plus.hcd ] && rm -f BCM4345C0.radxa,rock-4c-plus.hcd
ln -s BCM4345C0_003.001.025.0162.0000_Generic_UART_37_4MHz_wlbga_ref_iLNA_iTR_eLG.hcd BCM4345C0.radxa,rock-4c-plus.hcd

# Todo: add new firmware from Infineon (https://github.com/Infineon/ifx-linux-firmware)
[ -f brcmfmac43455-sdio.radxa,rock-4c-plus.bin ] && rm -f brcmfmac43455-sdio.radxa,rock-4c-plus.bin
ln -s ../cypress/cyfmac43455-sdio.bin brcmfmac43455-sdio.radxa,rock-4c-plus.bin

[ -f brcmfmac43455-sdio.radxa,rock-4c-plus.clm_blob ] && rm -f brcmfmac43455-sdio.radxa,rock-4c-plus.clm_blob
ln -s ../cypress/cyfmac43455-sdio.clm_blob brcmfmac43455-sdio.radxa,rock-4c-plus.clm_blob

popd