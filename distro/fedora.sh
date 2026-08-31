# Distro config for Fedora
# Sourced by install.sh — do not run directly.

DISTRO_PKGS=(fprintd gcc pkgconf libgusb-devel glib2-devel patchelf)
DISTRO_LIB_PATHS=(/usr/lib /usr/lib64)
DISTRO_PRIMARY_LIB_PATH=/usr/lib
DISTRO_HAS_SELINUX=1

distro_install() {
    sudo dnf install -y "$@"
}
