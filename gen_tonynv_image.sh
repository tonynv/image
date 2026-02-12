#!/usr/bin/env bash
#
# gen_tonynv_image.sh - Generate customized cloud images
#
# Downloads official cloud images (Debian, Ubuntu, Fedora) and injects
# cloud-init configuration to create the tonynv user, clone dotfiles,
# and run tonynv_setup.sh on first boot of each instance.
#
# The resulting image is a reusable template - create as many instances
# as needed, and each will run the setup exactly once on first boot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---
DISTRO="debian13"
PASSWD=""
USE_BOOTSTRAP=false
OUTPUT_DIR="${SCRIPT_DIR}/output"
CACHE_DIR="${SCRIPT_DIR}/.cache"

# --- Official cloud image URLs ---
declare -A IMAGE_URLS=(
    ["debian13"]="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
    ["ubuntu2404"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    ["fedora43"]="https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2"
)

declare -A DISTRO_LABELS=(
    ["debian13"]="Debian 13 (Trixie)"
    ["ubuntu2404"]="Ubuntu 24.04 LTS (Noble)"
    ["fedora43"]="Fedora 43"
)

# --- Functions ---

usage() {
    cat <<'EOF'
Usage: gen_tonynv_image.sh [OPTIONS]

Generate a customized cloud image with tonynv user and dotfiles setup.

Options:
  --distro <distro>   Target distro (default: debian13)
                      Supported: debian13, ubuntu2404, fedora43
  --passwd <password> Password for root and tonynv users
                      (generated randomly if not provided)
  --bootstrap         Include tonynv.userdata file as additional
                      cloud-init content
  -h, --help          Show this help message

Examples:
  ./gen_tonynv_image.sh
  ./gen_tonynv_image.sh --passwd mypassword
  ./gen_tonynv_image.sh --distro ubuntu2404 --passwd mypassword
  ./gen_tonynv_image.sh --distro fedora43 --bootstrap
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --distro)
                DISTRO="${2:-}"
                [[ -z "$DISTRO" ]] && { echo "Error: --distro requires a value"; exit 1; }
                shift 2
                ;;
            --passwd)
                PASSWD="${2:-}"
                [[ -z "$PASSWD" ]] && { echo "Error: --passwd requires a value"; exit 1; }
                shift 2
                ;;
            --bootstrap)
                USE_BOOTSTRAP=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Error: Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "${IMAGE_URLS[$DISTRO]+x}" ]]; then
        echo "Error: Unsupported distro '${DISTRO}'"
        echo "Supported: ${!IMAGE_URLS[*]}"
        exit 1
    fi

    if [[ -z "$PASSWD" ]]; then
        PASSWD="$(openssl rand -base64 12)"
    fi

    if [[ "$USE_BOOTSTRAP" == true && ! -f "${SCRIPT_DIR}/tonynv.userdata" ]]; then
        echo "Error: --bootstrap specified but tonynv.userdata not found in ${SCRIPT_DIR}"
        exit 1
    fi
}

install_deps() {
    echo "  Detecting package manager..."

    if command -v apt-get &>/dev/null; then
        echo "  Installing dependencies via apt..."
        sudo apt-get update -qq
        sudo apt-get install -y libguestfs-tools wget openssl
    elif command -v dnf &>/dev/null; then
        echo "  Installing dependencies via dnf..."
        sudo dnf install -y guestfs-tools wget openssl
    else
        echo "Error: Unsupported package manager. Install manually:"
        echo "  virt-customize, wget, openssl"
        exit 1
    fi
}

check_deps() {
    local missing=()
    for cmd in virt-customize wget openssl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "  Missing tools: ${missing[*]}"
        install_deps

        # Verify installation succeeded
        for cmd in virt-customize wget openssl; do
            if ! command -v "$cmd" &>/dev/null; then
                echo "Error: Failed to install ${cmd}"
                exit 1
            fi
        done
        echo "  All dependencies installed successfully."
    fi
}

download_image() {
    local url="${IMAGE_URLS[$DISTRO]}"
    local filename
    filename="$(basename "$url")"
    CACHED_IMAGE="${CACHE_DIR}/${filename}"

    mkdir -p "$CACHE_DIR"

    if [[ -f "$CACHED_IMAGE" ]]; then
        echo "  Using cached image: ${filename}"
    else
        echo "  Downloading ${DISTRO_LABELS[$DISTRO]} cloud image..."
        echo "  URL: ${url}"
        wget -q --show-progress -O "$CACHED_IMAGE" "$url"
    fi
}

build_cloud_config() {
    local outfile="$1"

    cat > "$outfile" <<CLOUDEOF
#cloud-config
users:
  - default
  - name: tonynv
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false

chpasswd:
  expire: false
  list: |
    root:${PASSWD}
    tonynv:${PASSWD}

ssh_pwauth: true

package_update: true

packages:
  - git
  - curl
  - zsh

write_files:
  - path: /etc/issue
    content: |
      Built with https://github.com/tonynv/image
      \S \r (\l)

  - path: /etc/motd
    content: |
      =========================================
       Built with https://github.com/tonynv/image
      =========================================

runcmd:
  - |
    # Enable serial console (grub + getty)
    if command -v grub2-mkconfig >/dev/null 2>&1; then
      GRUB_CFG="/etc/default/grub"
      sed -i 's/^GRUB_TERMINAL_OUTPUT=.*/GRUB_TERMINAL="serial console"/' "\$GRUB_CFG"
      grep -q '^GRUB_TERMINAL=' "\$GRUB_CFG" || echo 'GRUB_TERMINAL="serial console"' >> "\$GRUB_CFG"
      grep -q '^GRUB_SERIAL_COMMAND=' "\$GRUB_CFG" || echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"' >> "\$GRUB_CFG"
      sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 console=tty0 console=ttyS0,115200n8"/' "\$GRUB_CFG"
      grub2-mkconfig -o /boot/grub2/grub.cfg
    elif command -v update-grub >/dev/null 2>&1; then
      GRUB_CFG="/etc/default/grub"
      sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8"/' "\$GRUB_CFG"
      grep -q '^GRUB_TERMINAL=' "\$GRUB_CFG" || echo 'GRUB_TERMINAL="serial console"' >> "\$GRUB_CFG"
      grep -q '^GRUB_SERIAL_COMMAND=' "\$GRUB_CFG" || echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"' >> "\$GRUB_CFG"
      update-grub
    fi
    systemctl enable serial-getty@ttyS0.service
    systemctl start serial-getty@ttyS0.service || true
  - |
    # Clone dotfiles and run setup for root
    cd /root
    git clone https://github.com/tonynv/dotfiles.git
    cd dotfiles
    bash ./tonynv_setup.sh
  - |
    # Clone dotfiles and run setup for tonynv
    su - tonynv -c '
      cd ~
      git clone https://github.com/tonynv/dotfiles.git
      cd dotfiles
      bash ./tonynv_setup.sh
    '
CLOUDEOF

    if [[ "$USE_BOOTSTRAP" == true ]]; then
        local bootstrap_file="${SCRIPT_DIR}/tonynv.userdata"
        if head -1 "$bootstrap_file" | grep -q '^#cloud-config'; then
            # Cloud-config format: append directives (skip the #cloud-config header)
            tail -n +2 "$bootstrap_file" >> "$outfile"
        else
            # Shell script: add as runcmd entry
            {
                echo "  - |"
                echo "    # --- tonynv.userdata ---"
                sed 's/^/    /' "$bootstrap_file"
            } >> "$outfile"
        fi
    fi
}

customize_image() {
    local src_image="$1"
    local cloud_config="$2"
    OUTPUT_IMAGE="${OUTPUT_DIR}/tonynv-${DISTRO}.qcow2"

    mkdir -p "$OUTPUT_DIR"

    echo "  Copying base image..."
    cp "$src_image" "$OUTPUT_IMAGE"

    echo "  Injecting cloud-init configuration..."

    local customize_args=(
        -a "$OUTPUT_IMAGE"
        --mkdir /var/lib/cloud/seed/nocloud
        --upload "${cloud_config}:/var/lib/cloud/seed/nocloud/user-data"
        --write "/var/lib/cloud/seed/nocloud/meta-data:instance-id: iid-tonynv-template\nlocal-hostname: tonynv\n"
        --run-command "cloud-init clean --logs"
    )

    # SELinux relabel for Fedora
    if [[ "$DISTRO" == fedora* ]]; then
        customize_args+=(--selinux-relabel)
    fi

    virt-customize "${customize_args[@]}"
}

# --- Main ---

main() {
    parse_args "$@"
    check_deps

    echo "==========================================="
    echo " gen_tonynv_image.sh"
    echo "==========================================="
    echo "  Distro:    ${DISTRO_LABELS[$DISTRO]}"
    echo "  Bootstrap: ${USE_BOOTSTRAP}"
    echo "  Output:    ${OUTPUT_DIR}/"
    echo "==========================================="
    echo ""

    echo "[1/3] Downloading base image..."
    download_image
    echo ""

    echo "[2/3] Building cloud-init config..."
    TMPDIR_CLEANUP="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_CLEANUP"' EXIT

    local cloud_config="${TMPDIR_CLEANUP}/user-data"
    build_cloud_config "$cloud_config"
    echo ""

    echo "[3/3] Customizing image..."
    customize_image "$CACHED_IMAGE" "$cloud_config"
    echo ""

    echo "==========================================="
    echo " Image ready: ${OUTPUT_IMAGE}"
    echo "==========================================="
    echo ""
    echo " Password: ${PASSWD}"
    echo " (applies to both root and tonynv users)"
    echo ""
    echo " Boot with QEMU:"
    echo "   qemu-system-x86_64 -machine q35 -m 1024 -smp 2 \\"
    echo "     -enable-kvm -cpu host -nographic \\"
    echo "     -drive file=${OUTPUT_IMAGE},format=qcow2,if=virtio \\"
    echo "     -nic bridge,br=br-vlan200,model=virtio \\"
    echo "     -object rng-random,filename=/dev/urandom,id=rng0 \\"
    echo "     -device virtio-rng-pci,rng=rng0"
    echo ""
    echo " Import to libvirt:"
    echo "   virt-install --name tonynv-vm --ram 1024 --vcpus 2 \\"
    echo "     --machine q35 \\"
    echo "     --disk path=${OUTPUT_IMAGE},format=qcow2,bus=virtio \\"
    echo "     --network bridge=br-vlan200,model=virtio \\"
    echo "     --graphics none \\"
    echo "     --console pty,target_type=serial \\"
    echo "     --rng /dev/urandom \\"
    echo "     --tpm default \\"
    echo "     --import --os-variant detect=on"
    echo ""
}

main "$@"
