#!/bin/bash

set -Eeuo pipefail

trap 'echo >&2 "ERROR: Script failed at line ${LINENO}"' ERR

#
# Setup script for Rock 4 C+: configure DS3231 RTC on I2C7
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
# Ensure hwclock is available
# ---------------------------------------------------------------------------
if ! command -v hwclock >/dev/null 2>&1; then
    echo "hwclock not found, installing util-linux-extra"
    apt-get update
    apt-get install -y util-linux-extra
    if ! command -v hwclock >/dev/null 2>&1; then
        echo >&2 "ERROR: hwclock is still unavailable after installation"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Activate vendor I2C7 overlay
# Already present on the system — only needs registering, no compile step.
# ---------------------------------------------------------------------------
echo "Activating vendor overlay rk3399-i2c7"
activate_vendor_overlay "rk3399-i2c7"

# ---------------------------------------------------------------------------
# Write and compile DS3231 RTC overlay
#
# Registers a Maxim DS3231 RTC at I2C address 0x68 on the I2C7 bus.
# Requires the rk3399-i2c7 vendor overlay to be active (step above).
# ---------------------------------------------------------------------------
echo "Installing overlay rk3399-i2c7-ds3231"

mkdir -p "${BOOT_DIR}/overlay-user"
cat > "${BOOT_DIR}/overlay-user/rk3399-i2c7-ds3231.dtso" << '_EOF_'
/dts-v1/;
/plugin/;

/ {
	compatible = "rockchip,rk3399";

	fragment@0 {
		target = <&i2c7>;
		__overlay__ {
			#address-cells = <1>;
			#size-cells = <0>;

			ds3231: rtc@68 {
				compatible = "maxim,ds3231";
				reg = <0x68>;
			};
		};
	};
};
_EOF_

compile_overlay "rk3399-i2c7-ds3231"

# ---------------------------------------------------------------------------
# Disable fake-hwclock and install real hwclock service
# ---------------------------------------------------------------------------
echo "Disabling fake-hwclock"
systemctl stop fake-hwclock || true
systemctl disable fake-hwclock || true

echo "Creating hwclock service"
cat > /etc/systemd/system/hwclock.service << 'EOF'
[Unit]
Description=Hardware clock synchronization
DefaultDependencies=no
After=mutable.mount

[Service]
Type=oneshot
ExecStart=/sbin/hwclock --hctosys --utc --adjfile=/var/tmp/adjtime
ExecStop=/sbin/hwclock --systohc --utc --adjfile=/var/tmp/adjtime
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

systemctl daemon-reload
systemctl unmask hwclock.service
systemctl enable hwclock.service

echo "RTC DS3231 configuration completed successfully"
echo "A reboot is required to activate the device tree overlays"