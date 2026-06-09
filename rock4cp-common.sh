#!/bin/bash
# rock4cp-common.sh — shared helper functions for Rock 4C+ setup scripts
#
# Do not run directly. Source this file after downloading it:
#   source /tmp/rock4cp-common.sh

# ---------------------------------------------------------------------------
# Common variables — can be overridden by the calling script before sourcing
# ---------------------------------------------------------------------------
GH_USER="${GH_USER:-herrfrei}"
GH_REPO="${GH_REPO:-dietpi-rpk4cp}"
BRANCH="${BRANCH:-main}"
BOOT_DIR="${BOOT_DIR:-/boot}"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function check_root {
    if [[ "${EUID}" -ne 0 ]]; then
        echo >&2 "This script must be run as root"
        exit 1
    fi
}

function check_dietpi {
    if [[ ! -f /boot/dietpiEnv.txt ]]; then
        echo >&2 "This program only works on DietPi (missing /boot/dietpiEnv.txt)"
        exit 1
    fi
}

function check_writeable {
    local BOOT_RW_TEST="${BOOT_DIR}/.rw_test.$$"
    if ! touch "${BOOT_RW_TEST}" 2>/dev/null; then
        echo >&2 "ERROR: ${BOOT_DIR} is mounted read-only"
        echo >&2 "Remount read-write and run the script again"
        exit 1
    fi
    rm -f "${BOOT_RW_TEST}"
}

#
# Download a file with retry logic and timeout.
#
function download {
    local SRC="$1"
    local DEST="$2"
    local retries=5
    echo "Downloading ${SRC}"
    for ((i=1; i<=retries; i++)); do
        curl --fail --silent --show-error \
             --connect-timeout 10 --max-time 30 \
             -o "${DEST}" "${SRC}" && return 0
        echo >&2 "Attempt ${i}/${retries} failed, retrying..."
        sleep 2
    done
    echo >&2 "ERROR: Failed to download ${SRC} after ${retries} attempts"
    exit 1
}

#
# Download a helper script to /tmp/ and make it executable.
# Skips the download if the script is already present and executable.
#
function check_or_install_temp_script {
    local URL="$1"
    local SCRIPT_FILE
    SCRIPT_FILE=$(basename "${URL}")
    if [[ ! -x "/tmp/${SCRIPT_FILE}" ]]; then
        download "${URL}" "/tmp/${SCRIPT_FILE}"
        chmod +x "/tmp/${SCRIPT_FILE}"
    fi
}

#
# Ensure the device-tree-compiler is available.
# The overlay DTS is compiled locally so it matches the running kernel's
# base device tree — pre-compiled blobs may be incompatible across kernel
# versions (e.g. Linux 6.12 broke pre-built overlays).
#
function check_or_install_dtc {
    if ! command -v dtc >/dev/null 2>&1; then
        echo "device-tree-compiler not found, installing..."
        apt-get update
        apt-get install -y device-tree-compiler
        if ! command -v dtc >/dev/null 2>&1; then
            echo >&2 "ERROR: dtc is still unavailable after installation"
            exit 1
        fi
    fi
}

#
# Activate a vendor overlay that is already present on the system.
# Only registers the overlay name under the "overlays" key in dietpiEnv.txt.
# No .dtbo download or compilation is performed.
#
function activate_vendor_overlay {
    local OVERLAY="$1"
    check_or_install_temp_script \
        "https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${BRANCH}/dietpi-add-overlay"
    /tmp/dietpi-add-overlay "overlays" "${OVERLAY}"
}

#
# Compile a .dtso source file already written to overlay-user/ into a .dtbo
# and register it under the "user_overlays" key in dietpiEnv.txt.
#
# The -@ flag generates a __symbols__ section so this overlay can be
# referenced by other overlays, and produces correct __fixups__ for
# runtime phandle resolution against the base DTB.
#
function compile_overlay {
    local OVERLAY="$1"
    local DTSO_FILE="${BOOT_DIR}/overlay-user/${OVERLAY}.dtso"
    local DTBO_FILE="${BOOT_DIR}/overlay-user/${OVERLAY}.dtbo"

    check_or_install_dtc

    echo "Compiling overlay ${OVERLAY}"
    dtc -@ -I dts -O dtb -o "${DTBO_FILE}" "${DTSO_FILE}"

    check_or_install_temp_script \
        "https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${BRANCH}/dietpi-add-overlay"
    /tmp/dietpi-add-overlay "user_overlays" "${OVERLAY}"
}