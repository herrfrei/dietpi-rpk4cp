#!/bin/bash

set -Eeuo pipefail

trap 'echo >&2 "ERROR: Script failed at line ${LINENO}"' ERR

#
# Setup script for Rock 4 C+: install USB OTG peripheral mode device tree overlay
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
# Sets dr_mode = "peripheral" on the DWC3 USB 3.0 controller 0.
# The default mode on Rock 4C+ is "host" — this overlay switches it to
# peripheral (gadget / device) mode so the port can act as a USB device.
#
# status = "okay" is intentionally omitted: usbdrd_dwc3_0 is already
# enabled in the base DTS (host mode works out of the box). Repeating it
# in the overlay is redundant.
#
# maximum-speed = "super-speed" is added only when --super-speed is given.
# Without it the controller negotiates speed automatically with the host.
# ---------------------------------------------------------------------------
echo "Installing overlay rk3399-dwc3-0-peripheral"

mkdir -p "${BOOT_DIR}/overlay-user"

# Build DTS content. The maximum-speed line is only written when requested.
{
cat << '_EOF_'
/dts-v1/;
/plugin/;

/ {
	metadata {
		title = "Set OTG port to Peripheral mode";
		compatible = "rockchip,rk3399";
		category = "misc";
		exclusive = "usbdrd_dwc3_0-dr_mode";
		description = "Set OTG port to Peripheral mode.
Use this when you want to connect to another computer.";
	};
};

&usbdrd_dwc3_0 {
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