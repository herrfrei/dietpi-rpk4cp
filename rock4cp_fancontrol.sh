#!/bin/bash

set -Eeuo pipefail

trap 'echo >&2 "ERROR: Script failed at line ${LINENO}"' ERR

#
# Setup script for Rock 4 C+: PWM fan control via fancontrol daemon
#
# Two-phase install:
#   Phase 1 (this script): compiles and registers the PWM overlay,
#            installs fancontrol, writes a first-boot setup service.
#   Phase 2 (first boot):  rock4cp-fancontrol-setup detects the hwmon
#            numbers assigned to the fan and CPU sensor, writes
#            /etc/fancontrol, and starts the fancontrol service.
#
# Usage: rock4cp_fancontrol.sh [OPTIONS]
#
# Options:
#   --min-temp=N    CPU temperature (°C) at which fan starts     [default: 60]
#   --max-temp=N    CPU temperature (°C) for full speed          [default: 85]
#   --min-pwm=N     PWM value (0–255) when fan is at min-temp    [default: 0]
#   --max-pwm=N     PWM value (0–255) when fan is at max-temp    [default: 255]
#   --min-start=N   Minimum PWM needed to spin fan from stopped  [default: 64]
#   --min-stop=N    PWM below which running fan stops            [default: 48]
#

GH_USER="${GH_USER:-herrfrei}"
GH_REPO="${GH_REPO:-dietpi-rpk4cp}"
BRANCH="${BRANCH:-main}"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OPT_MIN_TEMP=60
OPT_MAX_TEMP=85
OPT_MIN_PWM=0
OPT_MAX_PWM=255
OPT_MIN_START=64
OPT_MIN_STOP=48

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "${arg}" in
        --min-temp=*)   OPT_MIN_TEMP="${arg#*=}" ;;
        --max-temp=*)   OPT_MAX_TEMP="${arg#*=}" ;;
        --min-pwm=*)    OPT_MIN_PWM="${arg#*=}" ;;
        --max-pwm=*)    OPT_MAX_PWM="${arg#*=}" ;;
        --min-start=*)  OPT_MIN_START="${arg#*=}" ;;
        --min-stop=*)   OPT_MIN_STOP="${arg#*=}" ;;
        *)
            echo >&2 "Unknown option: ${arg}"
            echo >&2 "Usage: $0 [--min-temp=N] [--max-temp=N] [--min-pwm=N] [--max-pwm=N] [--min-start=N] [--min-stop=N]"
            exit 1
            ;;
    esac
done

# Validate argument relationships
if [[ "${OPT_MIN_STOP}" -ge "${OPT_MIN_START}" ]]; then
    echo >&2 "ERROR: --min-stop (${OPT_MIN_STOP}) must be less than --min-start (${OPT_MIN_START})"
    exit 1
fi
if [[ "${OPT_MIN_TEMP}" -ge "${OPT_MAX_TEMP}" ]]; then
    echo >&2 "ERROR: --min-temp (${OPT_MIN_TEMP}) must be less than --max-temp (${OPT_MAX_TEMP})"
    exit 1
fi

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
# Install fancontrol package
# ---------------------------------------------------------------------------
echo "Installing fancontrol and lm-sensors"
apt-get update
apt-get install -y fancontrol lm-sensors

# ---------------------------------------------------------------------------
# Write and compile PWM fan overlay
#
# Fragment 0: enable PWM3 controller (pwm@ff420030, GPIO0_B2).
#             Pinctrl (pwm3a-pin) is already declared in the base DTS.
# Fragment 1: register the pwm-fan hwmon device node.
#             cooling-levels are required by the driver but ignored at
#             runtime — all speed control is handled by fancontrol.
# No thermal trips or cooling-maps: fancontrol bypasses the kernel
# thermal framework entirely.
# ---------------------------------------------------------------------------
echo "Installing overlay rk3399-pwm-fan"

mkdir -p "${BOOT_DIR}/overlay-user"

cat > "${BOOT_DIR}/overlay-user/rk3399-pwm-fan.dtso" << '_EOF_'
/dts-v1/;
/plugin/;

/ {
	metadata {
		title = "PWM Fan Control";
		compatible = "radxa,rock-4c-plus", "rockchip,rk3399";
		category = "misc";
		description = "Enable PWM fan on Rock 4C+ via PWM3 (GPIO0_B2, 2-pin 1.25mm 5V).
Speed is controlled by the fancontrol daemon. No kernel thermal trips are used.";
	};

	fragment@0 {
		target = <&pwm3>;
		__overlay__ {
			status = "okay";
		};
	};

	fragment@1 {
		target-path = "/";
		__overlay__ {
			fan0: pwm-fan {
				compatible     = "pwm-fan";
				#cooling-cells = <2>;
				cooling-levels = <0 64 128 192 255>;
				/* <controller  channel  period_ns  polarity> */
				pwms           = <&pwm3 0 40000 0>;
			};
		};
	};
};
_EOF_

compile_overlay "rk3399-pwm-fan"

# ---------------------------------------------------------------------------
# Write first-boot finalize script
#
# This script runs once after reboot when the overlay is active.
# It detects the hwmon numbers dynamically (they can vary between kernels
# and boot configurations), writes /etc/fancontrol with the correct paths,
# and starts the fancontrol service.
#
# The outer heredoc is unquoted so ${OPT_*} values are substituted now
# (compile time). Runtime variables inside the script are escaped as \${}.
# ---------------------------------------------------------------------------
cat > /usr/local/sbin/rock4cp-fancontrol-setup << EOF_SETUP
#!/bin/bash

set -Eeuo pipefail

LOG="/var/log/rock4cp-fancontrol-setup.log"
exec > >(tee -a "\${LOG}") 2>&1
echo "[\$(date)] rock4cp-fancontrol-setup starting"

# ---- Detect pwm-fan hwmon device ----------------------------------------
FAN_HWMON=""
for d in /sys/class/hwmon/hwmon*; do
    if [[ "\$(cat "\${d}/name" 2>/dev/null)" == "pwm_fan" ]]; then
        FAN_HWMON=\$(basename "\${d}")
        break
    fi
done

if [[ -z "\${FAN_HWMON}" ]]; then
    echo "ERROR: pwm-fan hwmon device not found. Is the overlay loaded?"
    exit 1
fi

# ---- Detect CPU thermal hwmon device ------------------------------------
# The cpu-thermal zone (tsadc channel 0) is exposed via thermal_hwmon.
# The kernel converts the zone name 'cpu-thermal' to 'cpu_thermal' for
# the hwmon name attribute (dashes replaced with underscores).
TEMP_HWMON=""
for d in /sys/class/hwmon/hwmon*; do
    if [[ "\$(cat "\${d}/name" 2>/dev/null)" == "cpu_thermal" ]]; then
        TEMP_HWMON=\$(basename "\${d}")
        break
    fi
done

if [[ -z "\${TEMP_HWMON}" ]]; then
    echo "ERROR: cpu_thermal hwmon device not found."
    exit 1
fi

# ---- Resolve stable sysfs device paths ---------------------------------
# DEVPATH entries let fancontrol re-resolve the correct hwmonX number on
# every start, so the config remains valid across kernel upgrades that may
# change hwmon numbering.
FAN_DEVPATH=\$(readlink -f "/sys/class/hwmon/\${FAN_HWMON}/device" | sed 's|/sys/||')
TEMP_DEVPATH=\$(readlink -f "/sys/class/hwmon/\${TEMP_HWMON}/device" | sed 's|/sys/||')
FAN_DEVNAME=\$(cat "/sys/class/hwmon/\${FAN_HWMON}/name")
TEMP_DEVNAME=\$(cat "/sys/class/hwmon/\${TEMP_HWMON}/name")

echo "Fan  hwmon : \${FAN_HWMON}  (\${FAN_DEVNAME} @ \${FAN_DEVPATH})"
echo "Temp hwmon : \${TEMP_HWMON} (\${TEMP_DEVNAME} @ \${TEMP_DEVPATH})"

# ---- Write /etc/fancontrol ----------------------------------------------
# OPT_* values were substituted at install time. Runtime paths (\${...})
# are expanded here when the setup service runs.
{
    echo "# /etc/fancontrol - Rock 4C+ PWM fan curve"
    echo "# Generated by rock4cp-fancontrol-setup on \$(date)"
    echo "#"
    echo "# Temperature → PWM interpolation (linear):"
    echo "#   Below ${OPT_MIN_TEMP}°C  → off  (PWM = ${OPT_MIN_PWM})"
    echo "#   At    ${OPT_MIN_TEMP}°C  → start pulse at ${OPT_MIN_START}, then interpolate"
    echo "#   ${OPT_MIN_TEMP}–${OPT_MAX_TEMP}°C  → PWM ${OPT_MIN_PWM} → ${OPT_MAX_PWM}"
    echo "#   Above ${OPT_MAX_TEMP}°C  → full speed (PWM = ${OPT_MAX_PWM})"
    echo ""
    echo "INTERVAL=3"
    echo ""
    echo "DEVPATH=\${FAN_HWMON}=\${FAN_DEVPATH} \${TEMP_HWMON}=\${TEMP_DEVPATH}"
    echo "DEVNAME=\${FAN_HWMON}=\${FAN_DEVNAME} \${TEMP_HWMON}=\${TEMP_DEVNAME}"
    echo ""
    echo "FCTEMPS=\${FAN_HWMON}/pwm1=\${TEMP_HWMON}/temp1_input"
    echo ""
    echo "MINTEMP=\${FAN_HWMON}/pwm1=${OPT_MIN_TEMP}"
    echo "MAXTEMP=\${FAN_HWMON}/pwm1=${OPT_MAX_TEMP}"
    echo "MINPWM=\${FAN_HWMON}/pwm1=${OPT_MIN_PWM}"
    echo "MAXPWM=\${FAN_HWMON}/pwm1=${OPT_MAX_PWM}"
    echo "MINSTART=\${FAN_HWMON}/pwm1=${OPT_MIN_START}"
    echo "MINSTOP=\${FAN_HWMON}/pwm1=${OPT_MIN_STOP}"
} > /etc/fancontrol

echo "fancontrol config written to /etc/fancontrol"

# ---- Enable and start fancontrol ----------------------------------------
systemctl enable --now fancontrol
echo "fancontrol service started"

# ---- Disable this one-shot service — job done ---------------------------
systemctl disable rock4cp-fancontrol-setup.service
echo "[\$(date)] rock4cp-fancontrol-setup complete"
EOF_SETUP

chmod +x /usr/local/sbin/rock4cp-fancontrol-setup

# ---------------------------------------------------------------------------
# Write the one-shot systemd service
#
# ConditionPathExists=!/etc/fancontrol ensures this runs only once.
# After=multi-user.target guarantees all hwmon devices are fully
# enumerated before the detection logic runs.
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/rock4cp-fancontrol-setup.service << 'EOF_SERVICE'
[Unit]
Description=Rock 4C+ fancontrol first-boot configuration
After=multi-user.target
ConditionPathExists=!/etc/fancontrol

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rock4cp-fancontrol-setup
StandardOutput=journal
StandardError=journal
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable rock4cp-fancontrol-setup.service

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "PWM fan control installation completed"
echo ""
echo "  Overlay  : rk3399-pwm-fan (compiled and registered in user_overlays)"
echo "  Service  : rock4cp-fancontrol-setup.service (runs once on next boot)"
echo ""
echo "  Fan curve settings baked into setup service:"
printf "    %-14s : %d°C\n"    "Start temp"   "${OPT_MIN_TEMP}"
printf "    %-14s : %d°C\n"    "Full speed"   "${OPT_MAX_TEMP}"
printf "    %-14s : %d – %d\n" "PWM range"    "${OPT_MIN_PWM}" "${OPT_MAX_PWM}"
printf "    %-14s : %d\n"      "MINSTART"     "${OPT_MIN_START}"
printf "    %-14s : %d\n"      "MINSTOP"      "${OPT_MIN_STOP}"
echo ""
echo "A reboot is required to activate the device tree overlay."
echo "fancontrol will be configured automatically on first boot."
echo "Check progress after reboot with:"
echo "  journalctl -u rock4cp-fancontrol-setup"
echo "  journalctl -u fancontrol"