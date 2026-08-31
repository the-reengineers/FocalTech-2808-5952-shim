# FocalTech 2808:5952 Fingerprint Sensor — Linux Driver

This document describes how to get the FocalTech fingerprint sensor `2808:5952` working on Linux, using the assets in this repository (which originally targeted `2808:a658`). The approach should work on any modern Linux distribution, though **only Fedora has been tested and confirmed**. The `install.sh` script includes support for Fedora, Ubuntu, and Arch Linux.

The approach combines three tricks:

1. **Device-table binary patch** — the proprietary driver has a hardcoded USB device table inside it. We repurposed an unused entry (`0xc652`) to claim `0x5952`.
2. **Compatibility shim** — the driver imports 6 `g_usb_*` symbols at version `LIBGUSB_0.1.0`, but modern `libgusb` only provides them at `LIBGUSB_0.2.8`. The shim (`focaltech-shim.so`) re-exports those symbols at the old version and forwards calls into the modern `libgusb` via `dlsym`.
3. **`LD_PRELOAD` instead of `patchelf --add-needed`** — on Fedora, the loader binds versioned-symbol lookups to the specific library filename recorded in the driver's `.gnu.version_r` section (i.e. `libgusb.so.2`), so `patchelf --add-needed focaltech-shim.so` does not cause the shim's symbols to be found. Preloading the shim into the global scope bypasses that binding. (The `--add-needed` approach works on Arch; we don't know why. On Fedora, only `LD_PRELOAD` was reliable.)

## Files required from this repo

| File | Purpose |
|------|---------|
| `driver/libfprint-2.so.2.0.0` | Proprietary FocalTech driver. We patch it (device table only). |
| `src/shim.c` | Source for the compatibility shim. |
| `src/shim.map` | Linker version script tagging the shim's symbols `LIBGUSB_0.1.0`. |
| `60-libfprint-2.rules` | udev rules. Already contains entries for `2808:5952` (added in this repo). |
| `focaltech-shim.so` | (Optional) Pre-built shim for OneXPlayer Super X on Fedora x86_64. Skip Step 2 if using this. |

`driver/libfprint-2.so.2.0.0.bak` is a backup of the unpatched driver — keep it around in case you need to roll back.

## Quick Installation

```bash
git clone <this-repo-url>
cd focaltech-ft9366-arch-shim
./install.sh
```

The script auto-detects your distribution (Fedora, Ubuntu, Arch, and derivatives), installs system packages, patches the driver, builds the compatibility shim, deploys everything, configures `fprintd` to load the shim via `LD_PRELOAD`, and restarts the service.

After installation, enroll your fingerprint:

```bash
fprintd-enroll -f right-index-finger
```

Tip: press your finger firmly on the sensor *before* running `fprintd-enroll` to keep the hardware awake during initialization.

**Fedora Workstation users:** you can also enroll fingerprints through the GUI at **Settings → Users → Fingerprint Login**.

## Manual Setup

If you prefer to perform each step by hand — or need to debug something the script doesn't cover — the full procedure is documented below.

## Prerequisites

```bash
sudo dnf install fprintd gcc pkgconf libgusb-devel glib2-devel patchelf
```

Confirm your sensor is visible:

```bash
lsusb | grep -i 2808:5952
# should show: FocalTech FocalTech Fingerprint Device
```

## Step 1 — Patch the device table in the driver

The driver has a hardcoded USB device table at file offset `0x182080` with four entries (vendor `0x2808`, products `0x9338`, `0xd979`, `0xc652`, `0xa658`). Each entry is a `uint32` product ID followed by a `uint32` vendor ID. We repurpose the `0xc652` entry — an obscure FocalTech ID unlikely to be needed — to claim `0x5952`.

```bash
cp libfprint-2.so.2.0.0 libfprint-2.so.2.0.0.bak   # back up first

python3 -c "
data = bytearray(open('libfprint-2.so.2.0.0','rb').read())
assert data[0x1820c0:0x1820c4] == bytes([0x52, 0xc6, 0x00, 0x00]), 'unexpected bytes at target offset'
data[0x1820c1] = 0x59
open('libfprint-2.so.2.0.0','wb').write(data)
print('patched: 0xc652 -> 0x5952 at offset 0x1820c0')
"
```

This is the only binary patch applied to the driver.

## Step 2 — Build the compatibility shim

**Or skip this step if you have a OneXPlayer Super X (AMD Ryzen AI Max+ 395) on Fedora x86_64** — a pre-built `focaltech-shim.so` is included in this repository and known to work on that hardware. Verify it has the required symbols:

```bash
nm -D focaltech-shim.so | grep g_usb
# should show 6 symbols at LIBGUSB_0.1.0
```

If the check passes, skip to Step 3. Otherwise, build from source:

The `-fvisibility=default -Wl,--export-dynamic` flags are required. Without them, the shim's symbols are compiled but never exported to the dynamic table, and the loader can't find them at runtime.

```bash
gcc -shared -fPIC -fvisibility=default \
    -Wl,--version-script=shim.map -Wl,--export-dynamic \
    -o focaltech-shim.so src/shim.c \
    $(pkg-config --cflags --libs glib-2.0) -ldl

# sanity check — should show 6 symbols at LIBGUSB_0.1.0
nm -D focaltech-shim.so | grep g_usb
```

## Step 3 — Deploy

On Fedora 64-bit, `fprintd` loads `libfprint-2.so.2` from `/lib/libfprint-2.so.2` → `/usr/lib/libfprint-2.so.2.0.0`. The `/usr/lib64/` copies are for anything else that links against libfprint. Both locations get the patched driver and the shim.

```bash
sudo cp libfprint-2.so.2.0.0 /usr/lib/libfprint-2.so.2.0.0
sudo cp libfprint-2.so.2.0.0 /usr/lib64/libfprint-2.so.2.0.0
sudo cp focaltech-shim.so /usr/lib/focaltech-shim.so
sudo cp focaltech-shim.so /usr/lib64/focaltech-shim.so

sudo chmod 755 \
    /usr/lib/libfprint-2.so.2.0.0 \
    /usr/lib64/libfprint-2.so.2.0.0 \
    /usr/lib/focaltech-shim.so \
    /usr/lib64/focaltech-shim.so

# Reset SELinux context so the loader is allowed to mmap them
sudo restorecon -v \
    /usr/lib/libfprint-2.so.2.0.0 \
    /usr/lib64/libfprint-2.so.2.0.0 \
    /usr/lib/focaltech-shim.so \
    /usr/lib64/focaltech-shim.so
```

Verify the driver loads cleanly (should list both `libgusb.so.2` and `focaltech-shim.so`, with no `not found`):

```bash
ldd /usr/lib/libfprint-2.so.2.0.0 | grep -E "focal|gusb|not found"
```

## Step 4 — Install udev rules

```bash
sudo cp 60-libfprint-2.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

## Step 5 — Disable USB autosuspend for the sensor

The kernel puts the sensor to sleep too aggressively; the driver then fails when it tries to talk to a sleeping device. The persistent udev rule below keeps it powered on.

```bash
sudo tee /etc/udev/rules.d/80-focaltech-fix.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2808", ATTR{idProduct}=="a658", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2808", ATTR{idProduct}=="5952", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger
```

For the currently-plugged device (the rule only takes effect on the next plug event), also do:

```bash
# find the device's sysfs path
for d in /sys/bus/usb/devices/*; do
  [ -f "$d/idVendor" ] && [ "$(cat "$d/idVendor")" = "2808" ] && [ "$(cat "$d/idProduct")" = "5952" ] && {
    echo -1 | sudo tee "$d/power/autosuspend"
    echo on | sudo tee "$d/power/control"
  }
done
```

## Step 6 — Make the shim load via `LD_PRELOAD`

On Fedora, the driver's `.gnu.version_r` binds `LIBGUSB_0.1.0` to the filename `libgusb.so.2`, so the loader looks for that version only in `libgusb.so.2` and doesn't fall back to `focaltech-shim.so` even though it's listed as a `DT_NEEDED` dependency. Preloading the shim puts its symbols in the global scope, which the loader *does* check as a fallback.

```bash
sudo mkdir -p /etc/systemd/system/fprintd.service.d
sudo tee /etc/systemd/system/fprintd.service.d/preload-shim.conf <<'EOF'
[Service]
Environment=LD_PRELOAD=/usr/lib/focaltech-shim.so
EOF

sudo systemctl daemon-reload
```

## Step 7 — Start and enroll

```bash
sudo systemctl restart fprintd
sleep 1
fprintd-list $(whoami)
# should report: "FocalTech Systems Co., Ltd fingerprint"

fprintd-enroll -f right-index-finger
# press your finger on the sensor when prompted (~5 times)

fprintd-verify
```

Tip: press your finger firmly on the sensor *before* running `fprintd-enroll` to keep the hardware awake during initialization.

**Fedora Workstation users:** you can also enroll fingerprints through the GUI at **Settings → Users → Fingerprint Login**.

## Step 8 (optional) — Use the fingerprint for `sudo` / login

Add to `/etc/pam.d/system-auth` (before the password line):

```
auth  sufficient  pam_fprintd.so
```

## Rollback

To undo everything:

```bash
sudo cp libfprint-2.so.2.0.0.bak /usr/lib/libfprint-2.so.2.0.0
sudo cp libfprint-2.so.2.0.0.bak /usr/lib64/libfprint-2.so.2.0.0
sudo chmod 755 /usr/lib/libfprint-2.so.2.0.0 /usr/lib64/libfprint-2.so.2.0.0
sudo restorecon -v /usr/lib/libfprint-2.so.2.0.0 /usr/lib64/libfprint-2.so.2.0.0
sudo rm /etc/systemd/system/fprintd.service.d/preload-shim.conf
sudo systemctl daemon-reload
sudo systemctl restart fprintd
```

## Fedora-specific gotchas discovered along the way

- `/usr/lib/` vs `/usr/lib64/`: `fprintd` loads from `/lib/libfprint-2.so.2` → `/usr/lib/...`. The README's original instructions only deployed to `/usr/lib/`. Deploy to both to cover everything.
- `glib2` on Fedora ships runtime only; `glib2-devel` is needed for the headers and `glib-2.0.pc`.
- Manually-copied `.so` files need `restorecon` to reset SELinux context; without it the loader silently refuses them.
- `systemctl enable fprintd` doesn't work (the unit has no `[Install]` section) — it's D-Bus activated. Just `restart` it.
- `patchelf --add-needed` is not sufficient on Fedora to make versioned symbols from a second library resolve. `LD_PRELOAD` is required.

## Tested devices

The only device this guide has been verified on is:

- **OneXPlayer Super X** — AMD Ryzen AI Max+ 395 (Halo Strix)

Reports from other hardware are welcome. If you get it working on a different machine, please open an issue or PR so the list can be expanded.

## Credits

This guide and the surrounding patches are derived from the [focaltech-ft9366-arch-shim](https://github.com/Klimentsi/focaltech-ft9366-arch-shim) repository by Klimentsi Katsko, which solved the same `libgusb` version-mismatch problem for the `2808:a658` sensor on Arch Linux. That project provided the original proprietary driver binary, the `shim.c` / `shim.map` compatibility layer, the udev rules, and the overall "proxy-shim" approach this guide builds on. The Fedora/`2808:5952` variations — device-table repurposing, visibility-flag compile fix, and `LD_PRELOAD` systemd drop-in — were worked out here on top of that foundation.

## Disclaimer

Generative AI was used to assist with the debugging and documentation of this work.
