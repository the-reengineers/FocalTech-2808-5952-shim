# Distro config for Arch Linux
# Sourced by install.sh — do not run directly.

DISTRO_PKGS=(fprintd gcc pkgconf libgusb patchelf)
DISTRO_LIB_PATHS=(/usr/lib)
DISTRO_PRIMARY_LIB_PATH=/usr/lib
DISTRO_HAS_SELINUX=0

distro_install() {
    sudo pacman -S --noconfirm --needed "$@"
}
