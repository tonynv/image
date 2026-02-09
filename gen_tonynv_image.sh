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
# Update these URLs as new releases become available.
declare -A IMAGE_URLS=(
    ["debian13"]="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
    ["ubuntu2404"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    ["fedora41"]="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
)

declare -A DISTRO_LABELS=(
    ["debian13"]="Debian 13 (Trixie)"
    ["ubuntu2404"]="Ubuntu 24.04 LTS (Noble)"
    ["fedora41"]="Fedora 41"
)

# --- Functions ---

usage() {
    cat <<'EOF'
Usage: gen_tonynv_image.sh [OPTIONS]

Generate a customized cloud image with tonynv user and dotfiles setup.

Options:
  --distro <distro>   Target distro (default: debian13)
                      Supported: debian13, ubuntu2404, fedora41
  --passwd <password> Password for root and tonynv users
                      (generated randomly if not provided)
  --bootstrap         Include tonynv.userdata file as additional
                      cloud-init runcmd content
  -h, --help          Show this help message

Examples:
  ./gen_tonynv_image.sh --passwd mypassword
  ./gen_tonynv_image.sh --distro ubuntu2404 --passwd mypassword
  ./gen_tonynv_image.sh --distro fedora41 --passwd mypassword --bootstrap
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
        GENERATED_PASSWD=true
    else
        GENERATED_PASSWD=false
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
    local cached="${CACHE_DIR}/${filename}"

    mkdir -p "$CACHE_DIR"

    if [[ -f "$cached" ]]; then
        echo "  Using cached image: ${filename}"
    else
        echo "  Downloading ${DISTRO_LABELS[$DISTRO]} cloud image..."
        echo "  URL: ${url}"
        wget -q --show-progress -O "$cached" "$url"
    fi

    echo "$cached"
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

runcmd:
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
    local output_name="tonynv-${DISTRO}.qcow2"
    local output_path="${OUTPUT_DIR}/${output_name}"

    mkdir -p "$OUTPUT_DIR"

    echo "  Copying base image..."
    cp "$src_image" "$output_path"

    echo "  Injecting cloud-init configuration..."

    local customize_args=(
        -a "$output_path"
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

    echo "$output_path"
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
    local cached_image
    cached_image="$(download_image)"
    echo ""

    echo "[2/3] Building cloud-init config..."
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    local cloud_config="${tmpdir}/user-data"
    build_cloud_config "$cloud_config"
    echo ""

    echo "[3/3] Customizing image..."
    local output_path
    output_path="$(customize_image "$cached_image" "$cloud_config")"
    echo ""

    echo "==========================================="
    echo " Image ready: ${output_path}"
    echo "==========================================="
    if [[ "$GENERATED_PASSWD" == true ]]; then
        echo ""
        echo " Generated password: ${PASSWD}"
        echo " (applies to both root and tonynv users)"
    fi
    echo ""
    echo " Boot with QEMU:"
    echo "   qemu-system-x86_64 -m 2048 -nographic \\"
    echo "     -drive file=${output_path},format=qcow2"
    echo ""
    echo " Import to libvirt:"
    echo "   virt-install --name tonynv-vm --ram 2048 --vcpus 2 \\"
    echo "     --disk path=${output_path},format=qcow2 \\"
    echo "     --import --os-variant generic --noautoconsole"
    echo ""
}

main "$@"
