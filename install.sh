#!/usr/bin/env bash
#
# install.sh — set up the FocalTech 2808:5952 fingerprint sensor.
#
# Supported distros: Fedora, Ubuntu, Arch Linux.
# Run as a regular user with sudo access:
#     chmod +x install.sh
#     ./install.sh
#
# See HOWTO.md for the full explanation of what each step does.

set -euo pipefail

readonly VENDOR_ID="2808"
readonly PRODUCT_ID="5952"
readonly SHIM_NAME="focaltech-shim.so"
readonly DRIVER_NAME="libfprint-2.so.2.0.0"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Resolve the directory this script lives in (follows symlinks).
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

require_file() {
    [[ -f "$SCRIPT_DIR/$1" ]] || die "required file '$1' not found in $SCRIPT_DIR"
}

# ---------------------------------------------------------------------------
# Distro detection
# ---------------------------------------------------------------------------

detect_distro() {
    if [[ ! -f /etc/os-release ]]; then
        die "/etc/os-release not found — cannot detect distro"
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID,,}" in
        fedora)
            echo "fedora"
            ;;
        ubuntu|linuxmint|debian|pop)
            echo "ubuntu"
            ;;
        arch|manjaro|endeavouros)
            echo "arch"
            ;;
        *)
            # Check ID_LIKE for derivatives
            case "${ID_LIKE,,}" in
                *fedora*)  echo "fedora"  ;;
                *ubuntu*|*debian*)  echo "ubuntu"  ;;
                *arch*)    echo "arch"    ;;
                *)         die "unsupported distro: $ID" ;;
            esac
            ;;
    esac
}

info "detecting distro"
DISTRO="$(detect_distro)"
info "detected: $DISTRO"

# Source the distro config.
DISTRO_CONFIG="$SCRIPT_DIR/distro/${DISTRO}.sh"
if [[ ! -f "$DISTRO_CONFIG" ]]; then
    die "distro config not found: $DISTRO_CONFIG"
fi
# shellcheck disable=SC1090
source "$DISTRO_CONFIG"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

info "checking prerequisites"

command -v sudo   >/dev/null || die "sudo is required"
command -v lsusb  >/dev/null || die "lsusb is required (install usbutils)"

# Make sure we can escalate privileges before we start.
sudo -v || die "sudo authentication failed"

# Confirm the sensor is actually present.
if ! lsusb -d "${VENDOR_ID}:${PRODUCT_ID}" | grep -qi focal; then
    die "sensor ${VENDOR_ID}:${PRODUCT_ID} not found on USB bus"
fi
echo "found sensor ${VENDOR_ID}:${PRODUCT_ID}"

# Confirm every source file we need is present.
for f in "driver/$DRIVER_NAME" src/shim.c src/shim.map 60-libfprint-2.rules; do
    require_file "$f"
done

# ---------------------------------------------------------------------------
# Step 1: install system packages
# ---------------------------------------------------------------------------

info "installing system packages"
distro_install "${DISTRO_PKGS[@]}"

# ---------------------------------------------------------------------------
# Step 2: patch the device table in the driver
# ---------------------------------------------------------------------------

info "patching device table (0xc652 -> 0x5952)"

cd "$SCRIPT_DIR"
cp -n "driver/$DRIVER_NAME" "driver/${DRIVER_NAME}.bak" || true   # back up, keep existing backup if any

python3 - "driver/$DRIVER_NAME" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
# Device-table entry for the repurposed product ID lives at file offset 0x1820c0:
# { uint32 product, uint32 vendor, uint32 zero, uint32 zero }
expected = bytes([0x52, 0xc6, 0x00, 0x00])
actual   = bytes(data[0x1820c0:0x1820c4])
if actual == bytes([0x52, 0x59, 0x00, 0x00]):
    print("already patched — skipping")
    sys.exit(0)
if actual != expected:
    print(f"unexpected bytes at 0x1820c0: {actual.hex()} (expected {expected.hex()})", file=sys.stderr)
    sys.exit(2)
data[0x1820c1] = 0x59
open(path, 'wb').write(data)
print("patched")
PY

# ---------------------------------------------------------------------------
# Step 3: build the compatibility shim
# ---------------------------------------------------------------------------

info "building focaltech-shim.so"

gcc -shared -fPIC -fvisibility=default \
    -Wl,--version-script=src/shim.map -Wl,--export-dynamic \
    -o "$SHIM_NAME" src/shim.c \
    $(pkg-config --cflags --libs glib-2.0) -ldl

# Sanity check: the shim MUST export the 6 g_usb_* symbols.
EXPORTED=$(nm -D "$SHIM_NAME" | grep -c 'g_usb.*@@LIBGUSB_0.1.0' || true)
[[ "$EXPORTED" -eq 6 ]] || die "shim did not export the expected 6 symbols (got $EXPORTED)"

# ---------------------------------------------------------------------------
# Step 4: deploy driver + shim
# ---------------------------------------------------------------------------

info "deploying to ${DISTRO_LIB_PATHS[*]}"

for dest in "${DISTRO_LIB_PATHS[@]}"; do
    sudo install -m 0755 "driver/$DRIVER_NAME" "$dest/$DRIVER_NAME"
    sudo install -m 0755 "$SHIM_NAME"          "$dest/$SHIM_NAME"
done

# Reset SELinux context so the loader is allowed to mmap them (Fedora only).
if [[ "$DISTRO_HAS_SELINUX" -eq 1 ]] && command -v restorecon >/dev/null; then
    RESTORECON_ARGS=()
    for dest in "${DISTRO_LIB_PATHS[@]}"; do
        RESTORECON_ARGS+=("$dest/$DRIVER_NAME" "$dest/$SHIM_NAME")
    done
    sudo restorecon -v "${RESTORECON_ARGS[@]}" || warn "restorecon failed — SELinux may block loading"
fi

# Verify the driver's dependencies resolve.
if ldd "${DISTRO_PRIMARY_LIB_PATH}/$DRIVER_NAME" | grep -q "not found"; then
    die "driver has unresolved dependencies:\n$(ldd "${DISTRO_PRIMARY_LIB_PATH}/$DRIVER_NAME" | grep 'not found')"
fi

# ---------------------------------------------------------------------------
# Step 5: install udev rules
# ---------------------------------------------------------------------------

info "installing udev rules"

sudo install -m 0644 60-libfprint-2.rules /etc/udev/rules.d/60-libfprint-2.rules

sudo tee /etc/udev/rules.d/80-focaltech-fix.rules >/dev/null <<EOF
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="${VENDOR_ID}", ATTR{idProduct}=="a658", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="${VENDOR_ID}", ATTR{idProduct}=="${PRODUCT_ID}", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger

# ---------------------------------------------------------------------------
# Step 6: disable USB autosuspend on the currently-plugged sensor
# ---------------------------------------------------------------------------

info "disabling autosuspend on the currently-plugged sensor"

found=0
for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" ]] || continue
    [[ "$(cat "$d/idVendor" 2>/dev/null)"  == "$VENDOR_ID" ]]   || continue
    [[ "$(cat "$d/idProduct" 2>/dev/null)" == "$PRODUCT_ID" ]] || continue
    echo -1 | sudo tee "$d/power/autosuspend" >/dev/null
    echo on | sudo tee "$d/power/control"     >/dev/null
    echo "applied to $d"
    found=1
done
[[ $found -eq 1 ]] || warn "sensor not found in /sys — autosuspend left at default (replug to apply)"

# ---------------------------------------------------------------------------
# Step 7: configure fprintd to LD_PRELOAD the shim
# ---------------------------------------------------------------------------

info "configuring fprintd systemd drop-in"

sudo mkdir -p /etc/systemd/system/fprintd.service.d
sudo tee /etc/systemd/system/fprintd.service.d/preload-shim.conf >/dev/null <<EOF
[Service]
Environment=LD_PRELOAD=${DISTRO_PRIMARY_LIB_PATH}/${SHIM_NAME}
EOF

sudo systemctl daemon-reload
sudo systemctl restart fprintd

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

sleep 1
if fprintd-list "$(whoami)" 2>/dev/null | grep -qi "fingerprint"; then
    info "sensor detected by fprintd"
    echo
    echo "Next step: enroll a finger with"
    echo
    echo "    fprintd-enroll -f right-index-finger"
    echo
else
    warn "fprintd did not report a fingerprint device."
    echo "Check logs with:  sudo journalctl -u fprintd -n 30 --no-pager"
fi
