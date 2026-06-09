#!/bin/bash

set -Eeuo pipefail

trap 'echo >&2 "ERROR: Script failed at line ${LINENO}"' ERR

#
# Setup script for Rock 4 C+: disable HDMI video and audio output
#
# Disables the Synopsys DesignWare HDMI controller and the associated
# HDMI sound card. Useful for headless servers to suppress display
# enumeration, reduce power draw and eliminate HDMI audio as an
# ALSA device so audio routing to other cards is unambiguous.
#
# Usage: rock4cp_disable_hdmi.sh
#

GH_USER="${GH_USER:-herrfrei}"
GH_REPO="${GH_REPO:-dietpi-rpk4cp}"
BRANCH="${BRANCH:-main}"

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
# Write and compile HDMI disable overlay
#
# Disables two nodes:
#   &hdmi       — Synopsys DW-HDMI controller @ ff940000
#                 Stops display enumeration and hot-plug detection.
#   &hdmi_sound — simple-audio-card bound to the HDMI output
#                 Removes the HDMI ALSA device so default audio routing
#                 falls through to other available sound cards.
#
# Note: compatible in metadata is "rockchip,rk3399" (the SoC identifier
# used for overlay matching). The original file incorrectly used
# "rockchip,rk3399-dw-hdmi" which is the IP block compatible string
# of the HDMI controller node itself, not a board/SoC identifier.
# ---------------------------------------------------------------------------
echo "Installing overlay rk3399-hdmi-disable"

mkdir -p "${BOOT_DIR}/overlay-user"

cat > "${BOOT_DIR}/overlay-user/rk3399-hdmi-disable.dtso" << '_EOF_'
/dts-v1/;
/plugin/;

/ {
	metadata {
		title = "Disable HDMI port";
		compatible = "rockchip,rk3399";
		category = "misc";
		description = "Disable HDMI video and sound output.";
	};
};

&hdmi {
	status = "disabled";
};

&hdmi_sound {
	status = "disabled";
};
_EOF_

compile_overlay "rk3399-hdmi-disable"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "HDMI disable installation completed"
echo ""
echo "  Overlay : rk3399-hdmi-disable (compiled and registered in user_overlays)"
echo ""
echo "  Effects after reboot:"
echo "    - HDMI display output disabled (no signal, no hot-plug detection)"
echo "    - HDMI ALSA sound device removed"
echo ""
echo "To re-enable HDMI, remove rk3399-hdmi-disable from user_overlays"
echo "in /boot/dietpiEnv.txt and reboot."
echo ""
echo "A reboot is required to activate the device tree overlay."