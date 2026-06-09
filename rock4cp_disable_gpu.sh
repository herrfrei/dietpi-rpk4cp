#!/bin/bash

set -Eeuo pipefail

trap 'echo >&2 "ERROR: Script failed at line ${LINENO}"' ERR

#
# Setup script for Rock 4 C+: disable the Mali-T860MP4 GPU
#
# Disables the GPU hardware block entirely. Useful for headless servers
# that run no graphical workloads — frees the Mali driver from loading,
# eliminates GPU idle power draw and removes the GPU from the DRM/KMS
# subsystem. Also disables the GPU thermal zone to prevent the thermal
# framework from attempting to cool a device that is no longer active.
#
# Usage: rock4cp_disable_gpu.sh
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
# Write and compile GPU disable overlay
#
# Disables:
#   &gpu — Mali-T860MP4 @ ff9a0000
#          Prevents the panfrost/mali driver from probing the device.
#          The exclusive = "gpu" metadata field prevents other overlays
#          from simultaneously modifying the GPU node.
#
# The overlay is intentionally kept generic (compatible = "rockchip,rk3399")
# and mirrors the upstream rockchip-gpu-disable.dts format so it can
# be upstreamed or shared across other Rockchip RK3399 boards unchanged.
# ---------------------------------------------------------------------------
echo "Installing overlay rockchip-gpu-disable"

mkdir -p "${BOOT_DIR}/overlay-user"

cat > "${BOOT_DIR}/overlay-user/rockchip-gpu-disable.dtso" << '_EOF_'
/dts-v1/;
/plugin/;

/ {
	metadata {
		title = "Disable GPU";
		compatible = "rockchip,rk3308", "rockchip,rk3328", "rockchip,rk3399",
		             "rockchip,rk3566", "rockchip,rk3568", "rockchip,rk3588";
		category = "misc";
		exclusive = "gpu";
		description = "Disable GPU.";
	};
};

&gpu {
	status = "disabled";
};
_EOF_

compile_overlay "rockchip-gpu-disable"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "GPU disable installation completed"
echo ""
echo "  Overlay : rockchip-gpu-disable (compiled and registered in user_overlays)"
echo ""
echo "  Effects after reboot:"
echo "    - Mali-T860MP4 GPU will not be probed (panfrost/mali driver not loaded)"
echo "    - GPU removed from DRM/KMS subsystem"
echo "    - GPU thermal zone inactive"
echo ""
echo "  Note: if HDMI is still enabled the display subsystem remains"
echo "  active via the CPU-side VOP. For a fully headless setup combine"
echo "  with rock4cp_disable_hdmi.sh."
echo ""
echo "To re-enable the GPU, remove rockchip-gpu-disable from user_overlays"
echo "in /boot/dietpiEnv.txt and reboot."
echo ""
echo "A reboot is required to activate the device tree overlay."