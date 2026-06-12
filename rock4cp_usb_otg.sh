#!/bin/bash
set -Eeuo pipefail
trap 'echo >&2 "ERROR: Script failed at line ${LINENO}"' ERR
#
# Setup script for Rock 4 C+: install USB OTG peripheral mode device tree overlay
#
# Enables USB OTG peripheral mode on the Rock 4C+ DWC3 controller.
# Also forces tcphy0 (pd_tcpd0) and usbdrd3_0 on, which is required to
# survive cold boots where the power domain would otherwise fail to
# initialize before the PHY probe times out.
#
# Usage: rock4cp_usb_otg.sh [OPTIONS]
#
# Options:
#   --super-speed   Add maximum-speed = "super-speed" to the overlay.
#                   Enables USB 3.0 SuperSpeed (5 Gbit/s) in peripheral mode.
#                   Omit this option to let the controller negotiate the
#                   highest speed automatically with the connected host.
#

GH_USER="${GH_USER:-herrfrei}"
GH_REPO="${GH_REPO:-dietpi-rpk4cp}"
BRANCH="${BRANCH:-main}"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
OPT_SUPER_SPEED=0
for arg in "$@"; do
    case "${arg}" in
        --super-speed)
            OPT_SUPER_SPEED=1
            ;;
        *)
            echo >&2 "Unknown option: ${arg}"
            echo >&2 "Usage: $0 [--super-speed]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Bootstrap: fetch and source shared helper functions
# ---------------------------------------------------------------------------
function _bootstrap_download {
    curl --fail --silent --show-error \
         --connect-timeout 10 --max-time 30 \
         -o "$2" "$1" || { echo >&2 "ERROR: Failed to download $1"; exit 1; }
}

_bootstrap_download \
    "https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${BRANCH}/rock4cp-common.sh" \
    "/tmp/rock4cp-common.sh"

# shellcheck source=/dev/null
source "/tmp/rock4cp-common.sh"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
check_dietpi
check_root
check_writeable

# ---------------------------------------------------------------------------
# Write and compile USB OTG peripheral mode overlay
#
# Fragment 0: enable usbdrd3_0 (the DWC3 USB3 controller wrapper).
# Fragment 1: enable tcphy0 (the Type-C combo PHY at ff7c0000).
#             Explicitly keeping this on ensures pd_tcpd0 is held active
#             on cold boot. Without this the power domain is released after
#             a failed PHY probe and never recovers until next warm reboot.
# Fragment 2: configure usbdrd_dwc3_0 for peripheral mode.
#             maximum-speed = "super-speed" is added only when --super-speed
#             is passed; otherwise the controller auto-negotiates with the host.
# ---------------------------------------------------------------------------
echo "Installing overlay rk3399-dwc3-0-peripheral"

mkdir -p "${BOOT_DIR}/overlay-user"

{
cat << '_EOF_'
/dts-v1/;
/plugin/;

/ {
	metadata {
		title = "Set OTG port to Peripheral mode";
		compatible = "radxa,rock-4c-plus", "rockchip,rk3399";
		category = "misc";
		description = "Set OTG port to Peripheral mode and keep pd_tcpd0 powered on cold boot.
Enables usbdrd3_0, tcphy0, and usbdrd_dwc3_0 explicitly to prevent the DWC3
PHY probe timeout that occurs after a full power cycle on the Rock 4C+.";
	};
};

&usbdrd3_0 {
	status = "okay";
};

&tcphy0 {
	status = "okay";
};

&usbdrd_dwc3_0 {
	status = "okay";
	dr_mode = "peripheral";
_EOF_
if [[ "${OPT_SUPER_SPEED}" -eq 1 ]]; then
    echo '	maximum-speed = "super-speed";'
fi
echo '};'
} > "${BOOT_DIR}/overlay-user/rk3399-dwc3-0-peripheral.dtso"

compile_overlay "rk3399-dwc3-0-peripheral"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "USB OTG configuration completed successfully"
if [[ "${OPT_SUPER_SPEED}" -eq 1 ]]; then
    echo "  Mode : peripheral (SuperSpeed 5 Gbit/s)"
else
    echo "  Mode : peripheral (auto-negotiated speed)"
fi
echo "A reboot is required to activate the device tree overlay"
