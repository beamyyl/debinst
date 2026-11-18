#!/bin/bash
# Debian installer using debootstrap
#
# Usage: ./debinstall.sh [release]     (default: trixie)
#
# Optional environment overrides:
#   MIRROR=https://deb.debian.org/debian
#   LOCALE=en_US.UTF-8
#   TIMEZONE=Europe/Berlin            (default: taken from the live system, else UTC)
set -Eeuo pipefail

# Hosts like Arch have no /usr/sbin in PATH, but Debian keeps useradd, chpasswd
# etc. there; chroot inherits this PATH, so make sure the sbin dirs are present.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
ask()   { echo -e "${CYAN}[INPUT]${NC} $*"; }
trap 'echo -e "${RED}[FAIL]${NC}  Command failed (line $LINENO): $BASH_COMMAND" >&2' ERR

RELEASE="${1:-trixie}"
TARGET="/mnt"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
SECURITY_MIRROR="https://security.debian.org/debian-security"
LOCALE="${LOCALE:-en_US.UTF-8}"
if [[ -z "${TIMEZONE:-}" ]]; then
    TIMEZONE="$(readlink -f /etc/localtime 2>/dev/null | sed -n 's|^/usr/share/zoneinfo/||p' || true)"
    TIMEZONE="${TIMEZONE:-UTC}"
fi

# ---------------------------------------------------------------------------
# Pre-flight checks (fail fast, before asking anything)
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run this script as root."
[[ "$RELEASE" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid release name: $RELEASE"
[[ "$(uname -m)" == "x86_64" ]] || die "Only amd64 (x86_64) hosts are supported."
mountpoint -q "$TARGET" || die "$TARGET is not a mountpoint. Please mount your root partition."
for cmd in chroot blkid findmnt mount umount; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command missing: $cmd"
done
if command -v apt-get >/dev/null 2>&1; then
    HOST_PM="apt"
elif command -v pacman >/dev/null 2>&1; then
    HOST_PM="pacman"
else
    die "Unsupported host. Use a Debian/Ubuntu or Arch-based live environment."
fi
[[ -z "$(ls -A "$TARGET" 2>/dev/null | grep -vxE 'lost\+found|boot|home' || true)" ]] ||
    warn "$TARGET is not empty — debootstrap may fail or mix with existing files."

echo "Installing Debian '${RELEASE}'. To pick another suite: ./debinstall.sh bookworm | sid"
echo

# ---------------------------------------------------------------------------
# Collect ALL input up front, so the rest runs unattended
# ---------------------------------------------------------------------------
if [[ -d /sys/firmware/efi ]]; then DEFAULT_BOOT=1; else DEFAULT_BOOT=2; fi
ask "Boot mode (live system was booted in $([[ $DEFAULT_BOOT == 1 ]] && echo UEFI || echo BIOS) mode):"
ask "  1) UEFI (modern, GPT disk)"
ask "  2) BIOS (legacy, MBR/GPT disk)"
read -rp "  Choice [$DEFAULT_BOOT]: " BOOT_CHOICE
BOOT_CHOICE="${BOOT_CHOICE:-$DEFAULT_BOOT}"

GRUB_DISK=""
case "$BOOT_CHOICE" in
    1)
        BOOT_MODE="uefi"
        [[ -d /sys/firmware/efi ]] ||
            warn "Live system is not booted in UEFI mode; grub-install may not register a boot entry."
        mountpoint -q "$TARGET/boot/efi" ||
            die "$TARGET/boot/efi is not a mountpoint. Mount your EFI System Partition there."
        ;;
    2)
        BOOT_MODE="bios"
        ask "Disk to install GRUB to (e.g. /dev/sda):"
        lsblk -dno PATH,SIZE,MODEL 2>/dev/null | sed 's/^/    /' || true
        read -rp "  Install disk: " GRUB_DISK
        [[ -n "$GRUB_DISK" ]] || die "Disk cannot be empty."
        [[ -b "$GRUB_DISK" ]] || die "$GRUB_DISK is not a block device."
        ;;
    *) die "Invalid boot mode choice." ;;
esac

ask "Hostname for the new system:"
read -rp "  Hostname [debian]: " NEW_HOSTNAME
NEW_HOSTNAME="${NEW_HOSTNAME:-debian}"
[[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die "Invalid hostname."

ask "Install the GNOME desktop environment (gnome-core)? [y/N]:"
read -rp "  Choice: " DESKTOP_CHOICE
[[ "$DESKTOP_CHOICE" =~ ^[Yy]$ ]] && INSTALL_DESKTOP="true" || INSTALL_DESKTOP="false"

ask "Username for the new user:"
read -rp "  Username: " NEW_USER
while [[ -z "$NEW_USER" ]]; do
    read -rp "  Username cannot be empty. Enter username: " NEW_USER
done
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username."
[[ "$NEW_USER" != "root" ]] || die "Pick a username other than root."

read_password() { # $1 = label, result in REPLY_PW
    local a b
    while true; do
        read -s -rp "  Enter password for $1: " a; echo
        [[ -n "$a" ]] || { warn "Password cannot be empty."; continue; }
        read -s -rp "  Confirm password for $1: " b; echo
        [[ "$a" == "$b" ]] && break
        warn "Passwords do not match, try again."
    done
    REPLY_PW="$a"
}
read_password "$NEW_USER"; USER_PASSWORD="$REPLY_PW"
read_password "root";      ROOT_PASSWORD="$REPLY_PW"
unset REPLY_PW

info "Locale: $LOCALE   Timezone: $TIMEZONE   Mirror: $MIRROR"
info "All input collected — the rest runs unattended."

# ---------------------------------------------------------------------------
# Host preparation
# ---------------------------------------------------------------------------
info "Preparing host tools..."
if [[ "$HOST_PM" == "apt" ]]; then
    need=()
    command -v debootstrap >/dev/null 2>&1 || need+=(debootstrap)
    command -v eatmydata   >/dev/null 2>&1 || need+=(eatmydata)
    if ((${#need[@]})); then
        apt-get update
        apt-get install -y "${need[@]}" || command -v debootstrap >/dev/null 2>&1
    fi
else
    need=()
    command -v debootstrap >/dev/null 2>&1 || need+=(debootstrap)
    command -v eatmydata   >/dev/null 2>&1 || need+=(libeatmydata)
    [[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]] || need+=(debian-archive-keyring)
    if ((${#need[@]})); then
        pacman -Sy --needed --noconfirm "${need[@]}"
    fi
fi
command -v debootstrap >/dev/null 2>&1 || die "debootstrap is still unavailable."

EMD=()
command -v eatmydata >/dev/null 2>&1 && EMD=(eatmydata)

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
DEBOOTSTRAP_ARGS=(
    --arch=amd64
    --components=main,contrib,non-free,non-free-firmware
    --include=ca-certificates,eatmydata,locales
)
KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
[[ -f "$KEYRING" ]] && DEBOOTSTRAP_ARGS+=(--keyring="$KEYRING")

info "Bootstrapping Debian ${RELEASE} into ${TARGET}..."
ok=false
for attempt in 1 2 3; do
    if "${EMD[@]}" debootstrap "${DEBOOTSTRAP_ARGS[@]}" "$RELEASE" "$TARGET" "$MIRROR"; then
        ok=true; break
    fi
    warn "debootstrap failed (attempt $attempt/3), retrying..."
    sleep 3
done
$ok || die "debootstrap failed. Check $TARGET/debootstrap/debootstrap.log"

# ---------------------------------------------------------------------------
# fstab — generated from everything currently mounted under $TARGET
# ---------------------------------------------------------------------------
info "Generating /etc/fstab..."
FS_PKGS=()
{
    echo "# <file system> <mount point> <type> <options> <dump> <pass>"
    while read -r mnt src fstype fsroot; do
        [[ "$src" == /dev/* ]] || continue
        src="${src%%\[*}"                      # strip btrfs "[/subvol]" suffix
        uuid="$(blkid -s UUID -o value "$src" || true)"
        [[ -n "$uuid" ]] || die "Could not determine UUID of $src."
        rel="${mnt#"$TARGET"}"; rel="${rel:-/}"
        case "$fstype" in
            ext2|ext3|ext4)
                if [[ "$rel" == / ]]; then opts="errors=remount-ro"; pass=1; else opts="defaults"; pass=2; fi ;;
            vfat)  opts="umask=0077"; pass=2; FS_PKGS+=(dosfstools) ;;
            btrfs) opts="defaults,subvol=${fsroot}"; pass=0; FS_PKGS+=(btrfs-progs) ;;
            xfs)   opts="defaults"; pass=0; FS_PKGS+=(xfsprogs) ;;
            f2fs)  opts="defaults"; pass=0; FS_PKGS+=(f2fs-tools) ;;
            *)     opts="defaults"; pass=0 ;;
        esac
        echo "UUID=$uuid $rel $fstype $opts 0 $pass"
    done < <(findmnt -R -n -l -o TARGET,SOURCE,FSTYPE,FSROOT "$TARGET")
} > "$TARGET/etc/fstab"
sed 's/^/    /' "$TARGET/etc/fstab"

echo "$NEW_HOSTNAME" > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" <<HOSTS
127.0.0.1   localhost
127.0.1.1   $NEW_HOSTNAME

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
HOSTS

# DNS inside the chroot
rm -f "$TARGET/etc/resolv.conf"
cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>/dev/null ||
    echo "nameserver 1.1.1.1" > "$TARGET/etc/resolv.conf"

# Non-secret settings for the chroot stage (passwords never touch disk)
CONFIG_FILE="$TARGET/root/.debian-installer-config"
{
    printf 'TARGET_RELEASE=%q\n'  "$RELEASE"
    printf 'TARGET_MIRROR=%q\n'   "$MIRROR"
    printf 'SECURITY_MIRROR=%q\n' "$SECURITY_MIRROR"
    printf 'BOOT_MODE=%q\n'       "$BOOT_MODE"
    printf 'GRUB_DISK=%q\n'       "$GRUB_DISK"
    printf 'INSTALL_DESKTOP=%q\n' "$INSTALL_DESKTOP"
    printf 'LOCALE=%q\n'          "$LOCALE"
    printf 'TIMEZONE=%q\n'        "$TIMEZONE"
    printf 'FS_PKGS=%q\n'         "${FS_PKGS[*]:-}"
} > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# ---------------------------------------------------------------------------
# Virtual filesystems
# ---------------------------------------------------------------------------
cleanup() {
    rm -f "$CONFIG_FILE" 2>/dev/null || true
    for dir in run sys proc dev; do
        if mountpoint -q "$TARGET/$dir"; then
            umount -R "$TARGET/$dir" 2>/dev/null || umount -R -l "$TARGET/$dir" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT

info "Mounting virtual filesystems..."
for dir in dev proc sys run; do
    mkdir -p "$TARGET/$dir"
    mount --rbind "/$dir" "$TARGET/$dir"
    mount --make-rslave "$TARGET/$dir"
done

# ---------------------------------------------------------------------------
# Chroot stage
# ---------------------------------------------------------------------------
info "Configuring Debian inside the target system..."
chroot "$TARGET" /usr/bin/env -i HOME=/root TERM="${TERM:-linux}" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash <<'CHROOT_EOF'
set -Eeuo pipefail
trap 'echo "[FAIL] chroot: command failed (line $LINENO): $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
source /root/.debian-installer-config

# --- APT: sources + speed/reliability tweaks --------------------------------
rm -f /etc/apt/sources.list
mkdir -p /etc/apt/sources.list.d
COMPONENTS="main contrib non-free non-free-firmware"
if [[ "$TARGET_RELEASE" == "sid" || "$TARGET_RELEASE" == "unstable" ]]; then
    # Debian unstable has no separate -updates or -security suites.
    cat > /etc/apt/sources.list.d/debian.sources <<SOURCES
Types: deb
URIs: ${TARGET_MIRROR}
Suites: ${TARGET_RELEASE}
Components: ${COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES
else
    cat > /etc/apt/sources.list.d/debian.sources <<SOURCES
Types: deb
URIs: ${TARGET_MIRROR}
Suites: ${TARGET_RELEASE} ${TARGET_RELEASE}-updates
Components: ${COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${SECURITY_MIRROR}
Suites: ${TARGET_RELEASE}-security
Components: ${COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES
fi

# Helper that makes sure every Debian repo (sources.list, *.list, *.sources)
# has main/contrib/non-free/non-free-firmware. Third-party repos are left alone.
# It is also hooked into "apt update" so repos added later get fixed too.
cat > /usr/local/sbin/debian-enable-all-components <<'HELPER'
#!/bin/sh
# Ensure all Debian archive repos have: main contrib non-free non-free-firmware
set -eu
WANT="main contrib non-free non-free-firmware"
# Official Debian archive / mirrors only (deb.debian.org, security.debian.org,
# ftp.XX.debian.org, or any mirror path ending in /debian or /debian-security)
RE='(debian[.]org|/debian(-security|-backports)?/?)([[:space:]]|$)'

fix_file() {
    f="$1"; tmp="$(mktemp)"
    case "$f" in
    *.sources)
        awk -v want="$WANT" -v re="$RE" '
        function addc(line,   rest, n, H, have, i, W) {
            rest = line; sub(/^[Cc]omponents:[[:space:]]*/, "", rest)
            n = split(rest, H, /[[:space:]]+/)
            for (i = 1; i <= n; i++) have[H[i]] = 1
            split(want, W, " ")
            for (i = 1; i in W; i++) if (!(W[i] in have)) rest = rest " " W[i]
            return "Components: " rest
        }
        function flush(   i, l, deb) {
            deb = (uris ~ re)
            for (i = 1; i <= n; i++) {
                l = buf[i]
                if (deb && l ~ /^[Cc]omponents:/) l = addc(l)
                print l
            }
            n = 0; uris = ""
        }
        /^[[:space:]]*$/ { flush(); print; next }
        { buf[++n] = $0; if ($0 ~ /^[Uu][Rr][Ii][Ss]:/) uris = $0 " " }
        END { flush() }' "$f" > "$tmp" ;;
    *)
        awk -v want="$WANT" -v re="$RE" '
        /^[[:space:]]*deb(-src)?[[:space:]]/ && $0 !~ /#/ {
            i = 2
            if ($2 ~ /^\[/) { while (i <= NF && $i !~ /\]$/) i++; i++ }
            uri = $i; suite = $(i + 1)
            if ((uri " ") ~ re && suite !~ /\/$/) {
                delete have
                for (j = i + 2; j <= NF; j++) have[$j] = 1
                split(want, W, " ")
                for (k = 1; k in W; k++) if (!(W[k] in have)) $0 = $0 " " W[k]
            }
        }
        { print }' "$f" > "$tmp" ;;
    esac
    if ! cmp -s "$f" "$tmp"; then
        cat "$tmp" > "$f"
        echo "enabled contrib/non-free/non-free-firmware in $f"
    fi
    rm -f "$tmp"
}

for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] && fix_file "$f"
done
exit 0
HELPER
chmod 755 /usr/local/sbin/debian-enable-all-components

cat > /etc/apt/apt.conf.d/05enable-all-components <<'APTHOOK'
// Keep contrib/non-free/non-free-firmware enabled on all Debian repos.
// Remove this file to stop apt update from touching your sources.
APT::Update::Pre-Invoke { "if [ -x /usr/local/sbin/debian-enable-all-components ]; then /usr/local/sbin/debian-enable-all-components; fi || true"; };
APTHOOK

/usr/local/sbin/debian-enable-all-components

# Temporary install-time settings (removed at the end)
cat > /etc/apt/apt.conf.d/99installer-tmp <<'APTCONF'
Acquire::Retries "5";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::Languages "none";
APT::Install-Suggests "false";
Dpkg::Options { "--force-confdef"; "--force-confold"; };
Dpkg::Use-Pty "false";
APTCONF

# Skip the slow man-db index rebuild on every package install
echo "man-db man-db/auto-update boolean false" | debconf-set-selections
rm -f /var/lib/man-db/auto-update

if [[ "$BOOT_MODE" == "bios" ]]; then
    echo "grub-pc grub-pc/install_devices multiselect $GRUB_DISK" | debconf-set-selections
fi

dpkg --add-architecture i386
apt-get update

# Return only packages that actually exist in this release (keeps the
# install working on bookworm/trixie/sid where package names drift).
available() {
    local p
    for p in "$@"; do
        # (no grep -q pipe: with pipefail an early grep exit can SIGPIPE apt-cache)
        if [[ "$(apt-cache policy "$p" 2>/dev/null || true)" =~ Candidate:\ [^\(] ]]; then
            echo "$p"
        else
            echo "    (skipping unavailable package: $p)" >&2
        fi
    done
}

# --- Package selection ------------------------------------------------------
BASE_PKGS=(
    linux-image-amd64 firmware-linux network-manager
    sudo bash locales man-db dbus systemd-sysv systemd-timesyncd
    bash-completion
)
[[ "$BOOT_MODE" == "uefi" ]] && BASE_PKGS+=(grub-efi-amd64 efibootmgr) || BASE_PKGS+=(grub-pc)
# shellcheck disable=SC2206
BASE_PKGS+=($FS_PKGS)

# Mesa / FOSS graphics stack: OpenGL, EGL, GBM, Vulkan (radv/anv/nvk), VA-API
GRAPHICS_REQUIRED=(
    libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgbm1
    mesa-vulkan-drivers libvulkan1
)
OPTIONAL_PKGS=(
    # Video acceleration (FOSS)
    mesa-va-drivers mesa-vdpau-drivers intel-media-va-driver i965-va-driver
    # Diagnostics: glxinfo/eglinfo, vulkaninfo, vainfo
    mesa-utils vulkan-tools vainfo
    # 32-bit Mesa for Steam / Wine
    libgl1-mesa-dri:i386 libglx-mesa0:i386 libegl-mesa0:i386
    mesa-vulkan-drivers:i386 libvulkan1:i386
    # Device firmware (needed by the in-kernel FOSS drivers) + CPU microcode
    firmware-amd-graphics firmware-misc-nonfree firmware-iwlwifi firmware-realtek
    firmware-atheros firmware-brcm80211 firmware-sof-signed
    amd64-microcode intel-microcode
)
DESKTOP_PKGS=()
if [[ "$INSTALL_DESKTOP" == "true" ]]; then
    DESKTOP_PKGS=(gnome-core gdm3 flatpak gnome-software-plugin-flatpak)
fi

mapfile -t OPTIONAL_OK < <(available "${OPTIONAL_PKGS[@]}")

# One single transaction: dependency resolution, initramfs and grub triggers
# run once instead of once per apt-get call.
echo "--> Installing base system, kernel, Mesa/FOSS drivers${DESKTOP_PKGS:+ and GNOME}..."
eatmydata apt-get install -y \
    "${BASE_PKGS[@]}" "${GRAPHICS_REQUIRED[@]}" "${OPTIONAL_OK[@]}" "${DESKTOP_PKGS[@]}"

# Let regular users have sbin in PATH as well
sed -i.bak '/^if \[ "\$(id -u)" -eq 0 \]; then/,/^fi$/c\PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/games:/usr/games"' /etc/profile

# --- Locale & timezone ------------------------------------------------------
echo "--> Configuring locale ($LOCALE) and timezone ($TIMEZONE)..."
if grep -qE "^# *${LOCALE} " /etc/locale.gen; then
    sed -i "s/^# *\(${LOCALE} .*\)/\1/" /etc/locale.gen
elif ! grep -qE "^${LOCALE} " /etc/locale.gen; then
    echo "${LOCALE} ${LOCALE#*.}" >> /etc/locale.gen
fi
locale-gen
update-locale LANG="$LOCALE"
if [[ -e "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone
fi

# --- Services ---------------------------------------------------------------
systemctl enable NetworkManager systemd-timesyncd 2>/dev/null || systemctl enable NetworkManager
if [[ "$INSTALL_DESKTOP" == "true" ]]; then
    systemctl enable gdm3 2>/dev/null || true
    systemctl set-default graphical.target
    flatpak remote-add --system --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo || echo "    (flathub remote not added; run it after boot)"
fi

# --- Bootloader -------------------------------------------------------------
echo "--> Installing GRUB..."
if [[ "$BOOT_MODE" == "uefi" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --bootloader-id=Debian --recheck
    # Also install to the fallback path EFI/BOOT/BOOTX64.EFI; some firmware
    # ignores NVRAM entries or loses them.
    grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --removable --no-nvram
    echo "grub-efi-amd64 grub2/force_efi_extra_removable boolean true" | debconf-set-selections
else
    grub-install --target=i386-pc --recheck "$GRUB_DISK"
fi
update-grub

# --- Cleanup ----------------------------------------------------------------
echo "man-db man-db/auto-update boolean true" | debconf-set-selections
touch /var/lib/man-db/auto-update
rm -f /etc/apt/apt.conf.d/99installer-tmp
apt-get clean
CHROOT_EOF

# ---------------------------------------------------------------------------
# Users (passwords are piped straight in, never written to disk)
# ---------------------------------------------------------------------------
info "Creating users..."
GROUPS_WANTED=(sudo plugdev netdev audio video input render)
GROUPS_OK=()
for g in "${GROUPS_WANTED[@]}"; do
    chroot "$TARGET" getent group "$g" >/dev/null && GROUPS_OK+=("$g")
done
GROUP_LIST="$(IFS=,; echo "${GROUPS_OK[*]}")"

chroot "$TARGET" useradd -m -s /bin/bash ${GROUP_LIST:+-G "$GROUP_LIST"} "$NEW_USER"
printf '%s:%s\n' "$NEW_USER" "$USER_PASSWORD" | chroot "$TARGET" chpasswd
printf 'root:%s\n'           "$ROOT_PASSWORD" | chroot "$TARGET" chpasswd
chroot "$TARGET" chsh -s /bin/bash root
unset USER_PASSWORD ROOT_PASSWORD

sync
cleanup
trap - EXIT

echo
info "Debian ${RELEASE} has been installed to ${TARGET}."
echo "You can now unmount ${TARGET} and reboot."
