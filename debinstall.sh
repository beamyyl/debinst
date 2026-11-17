#!/bin/bash
# Debian installer using debootstrap
set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
ask()   { echo -e "${CYAN}[INPUT]${NC} $*"; }

RELEASE="${1:-trixie}"
TARGET="/mnt"
MIRROR="https://deb.debian.org/debian"
SECURITY_MIRROR="https://security.debian.org/debian-security"

[[ "$RELEASE" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid release name: $RELEASE"

if ! mountpoint -q "$TARGET"; then
    die "$TARGET is not a target mountpoint. Please mount your root partition."
fi

echo "The default Debian release is trixie."
echo "To install another suite, pass it as the first argument:"
echo "  ./debian-install.sh bookworm"
echo "  ./debian-install.sh sid"
echo "Make sure the selected suite is supported by Debian and debootstrap."
sleep 1

ask "Boot mode — are you using UEFI or BIOS?"
ask "  1) UEFI (modern, GPT disk)"
ask "  2) BIOS (legacy, MBR/GPT disk)"
read -rp "  Choice [1/2]: " BOOT_CHOICE

case "$BOOT_CHOICE" in
    1)
        BOOT_MODE="uefi"
        mountpoint -q "$TARGET/boot/efi" ||
            die "$TARGET/boot/efi is not a target mountpoint. Mount your EFI System Partition there."
        ;;
    2)
        BOOT_MODE="bios"
        ask "Enter the disk to install GRUB to (e.g. /dev/sda):"
        read -rp "  Install disk: " GRUB_DISK
        [[ -n "${GRUB_DISK:-}" ]] || die "Disk cannot be empty."
        [[ -b "$GRUB_DISK" ]] || die "$GRUB_DISK is not a block device."
        ;;
    *) die "Invalid boot mode choice." ;;
esac

ask "Enter desired hostname for the new system:"
read -rp "  Hostname [debian]: " HOSTNAME
HOSTNAME="${HOSTNAME:-debian}"
[[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die "Invalid hostname."

ask "Install the GNOME desktop environment (gnome-core)? [y/N]:"
read -rp "  Choice: " DESKTOP_CHOICE
[[ "$DESKTOP_CHOICE" =~ ^[Yy]$ ]] && INSTALL_DESKTOP="true" || INSTALL_DESKTOP="false"

info "Checking host environment and debootstrap..."
if command -v apt-get >/dev/null 2>&1; then
    if ! command -v debootstrap >/dev/null 2>&1; then
        info "Installing debootstrap on the live environment..."
        apt-get update
        apt-get install -y debootstrap
    fi
elif command -v pacman >/dev/null 2>&1; then
    if ! command -v debootstrap >/dev/null 2>&1; then
        info "Installing debootstrap via pacman..."
        pacman -Sy --needed --noconfirm debootstrap libeatmydata
    fi
else
    die "Unsupported host. Use a Debian/Ubuntu or Arch-based live environment."
fi

command -v debootstrap >/dev/null 2>&1 || die "debootstrap is still unavailable."
command -v chroot >/dev/null 2>&1 || die "The chroot command is unavailable."
command -v blkid >/dev/null 2>&1 || die "blkid is required."
command -v findmnt >/dev/null 2>&1 || die "findmnt is required."

ask "Enter desired username for the new user:"
read -rp "  Username: " NEW_USER
while [[ -z "$NEW_USER" ]]; do
    read -rp "  Username cannot be empty. Enter username: " NEW_USER
done
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid username."

read -s -rp "  Enter password for $NEW_USER: " USER_PASSWORD
echo
read -s -rp "  Confirm password for $NEW_USER: " USER_PASSWORD_CONFIRM
echo
[[ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]] || die "User passwords do not match."

read -s -rp "  Enter password for root account: " ROOT_PASSWORD
echo
read -s -rp "  Confirm password for root account: " ROOT_PASSWORD_CONFIRM
echo
[[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]] || die "Root passwords do not match."

info "Bootstrapping Debian ${RELEASE} into ${TARGET}..."
DEBOOTSTRAP_ARGS=(--arch=amd64)
if [[ -x /usr/bin/eatmydata ]]; then
    eatmydata debootstrap "${DEBOOTSTRAP_ARGS[@]}" "$RELEASE" "$TARGET" "$MIRROR"
else
    debootstrap "${DEBOOTSTRAP_ARGS[@]}" "$RELEASE" "$TARGET" "$MIRROR"
fi

info "Generating /etc/fstab..."
ROOT_SOURCE="$(findmnt -n -o SOURCE --target "$TARGET")"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_SOURCE")"
[[ -n "$ROOT_UUID" ]] || die "Could not determine the root filesystem UUID."
cat > "$TARGET/etc/fstab" <<FSTAB
UUID=$ROOT_UUID / ext4 errors=remount-ro 0 1
FSTAB

if [[ "$BOOT_MODE" == "uefi" ]]; then
    EFI_SOURCE="$(findmnt -n -o SOURCE --target "$TARGET/boot/efi")"
    EFI_UUID="$(blkid -s UUID -o value "$EFI_SOURCE")"
    [[ -n "$EFI_UUID" ]] || die "Could not determine the EFI filesystem UUID."
    echo "UUID=$EFI_UUID /boot/efi vfat umask=0077 0 2" >> "$TARGET/etc/fstab"
fi

echo "$HOSTNAME" > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" <<HOSTS
127.0.0.1   localhost
127.0.1.1   $HOSTNAME

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
HOSTS

CONFIG_FILE="$TARGET/root/.debian-installer-config"
{
    printf 'TARGET_RELEASE=%q\n' "$RELEASE"
    printf 'TARGET_MIRROR=%q\n' "$MIRROR"
    printf 'SECURITY_MIRROR=%q\n' "$SECURITY_MIRROR"
    printf 'NEW_USER=%q\n' "$NEW_USER"
    printf 'USER_PASSWORD=%q\n' "$USER_PASSWORD"
    printf 'ROOT_PASSWORD=%q\n' "$ROOT_PASSWORD"
    printf 'BOOT_MODE=%q\n' "$BOOT_MODE"
    printf 'GRUB_DISK=%q\n' "${GRUB_DISK:-}"
    printf 'INSTALL_DESKTOP=%q\n' "$INSTALL_DESKTOP"
} > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
unset USER_PASSWORD USER_PASSWORD_CONFIRM ROOT_PASSWORD ROOT_PASSWORD_CONFIRM

info "Mounting virtual filesystems..."
for dir in dev dev/pts proc sys run; do
    mkdir -p "$TARGET/$dir"
    mount --rbind "/$dir" "$TARGET/$dir"
    mount --make-rslave "$TARGET/$dir"
done

cleanup() {
    for dir in run sys proc dev/pts dev; do
        mountpoint -q "$TARGET/$dir" && umount -R "$TARGET/$dir" 2>/dev/null || true
    done
}
trap cleanup EXIT

info "Configuring Debian inside the target system..."
chroot "$TARGET" /bin/bash <<'CHROOT_EOF'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
source /root/.debian-installer-config
rm -f /etc/apt/sources.list
mkdir -p /etc/apt/sources.list.d

if [[ "$TARGET_RELEASE" == "sid" || "$TARGET_RELEASE" == "unstable" ]]; then
    # Debian unstable has no separate -updates or -security suites.
    cat > /etc/apt/sources.list.d/debian.sources <<SOURCES
Types: deb
URIs: ${TARGET_MIRROR}
Suites: ${TARGET_RELEASE}
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES
else
    cat > /etc/apt/sources.list.d/debian.sources <<SOURCES
Types: deb
URIs: ${TARGET_MIRROR}
Suites: ${TARGET_RELEASE} ${TARGET_RELEASE}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${SECURITY_MIRROR}
Suites: ${TARGET_RELEASE}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES
fi

dpkg --add-architecture i386
apt-get update
apt-get install -y ca-certificates debian-archive-keyring

echo "--> Installing base system, kernel, networking, and utilities..."
apt-get install -y \
    linux-image-amd64 \
    firmware-linux \
    firmware-linux-nonfree \
    network-manager \
    sudo \
    bash \
    locales \
    man-db \
    dbus \
    systemd-sysv

if [[ "$BOOT_MODE" == "uefi" ]]; then
    apt-get install -y grub-efi-amd64
else
    apt-get install -y grub-pc
fi

if [[ "$INSTALL_DESKTOP" == "true" ]]; then
    echo "--> Installing GNOME..."
    apt-get install -y gnome-core gdm3 network-manager flatpak gnome-software-plugin-flatpak
    systemctl enable NetworkManager gdm3
    if command -v flatpak >/dev/null 2>&1; then
        flatpak remote-add --system --if-not-exists flathub \
            https://dl.flathub.org/repo/flathub.flatpakrepo || true
    fi
else
    systemctl enable NetworkManager
fi

echo "--> Configuring GRUB..."
if [[ "$BOOT_MODE" == "uefi" ]]; then
    sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --bootloader-id=Debian --recheck
else
    sudo grub-install --target=i386-pc "$GRUB_DISK"
fi
sudo update-grub

echo "--> Provisioning users and credentials..."
echo "root:${ROOT_PASSWORD}" | chpasswd
chsh -s /bin/bash root

useradd -m -s /bin/bash -G sudo,plugdev,netdev,audio,video,input "$NEW_USER"
echo "${NEW_USER}:${USER_PASSWORD}" | chpasswd

rm -f /root/.debian-installer-config
apt-get clean
CHROOT_EOF

cleanup
trap - EXIT

echo
info "Debian ${RELEASE} has been installed to ${TARGET}."
echo "You can now reboot into your new system."
