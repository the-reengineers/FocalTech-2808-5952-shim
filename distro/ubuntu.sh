# Distro config for Ubuntu (x86_64)
# Sourced by install.sh — do not run directly.

DISTRO_PKGS=(fprintd gcc pkg-config libgusb-dev libglib2.0-dev patchelf)
DISTRO_LIB_PATHS=(/usr/lib/x86_64-linux-gnu)
DISTRO_PRIMARY_LIB_PATH=/usr/lib/x86_64-linux-gnu
DISTRO_HAS_SELINUX=0

distro_install() {
    sudo apt update
    sudo apt install -y "$@"
}
