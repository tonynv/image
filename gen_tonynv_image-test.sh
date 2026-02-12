#!/usr/bin/env bash
#
# gen_tonynv_image-test.sh - Tests for gen_tonynv_image.sh
#
# For each supported distro: builds the image, inspects the injected
# cloud-init configuration, and boots with QEMU to verify the login
# banner and that the VM reaches a login prompt.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DISTROS=("debian13" "ubuntu2404" "fedora43")
TEST_PASSWD="testpass123"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() {
    ((TESTS_PASSED++))
    ((TESTS_RUN++))
    echo -e "  ${GREEN}PASS${NC} $1"
}

fail() {
    ((TESTS_FAILED++))
    ((TESTS_RUN++))
    echo -e "  ${RED}FAIL${NC} $1"
    [[ -n "${2:-}" ]] && echo -e "       $2"
}

# -------------------------------------------------------
# Build tests
# -------------------------------------------------------
test_build() {
    local distro="$1"
    local output="${SCRIPT_DIR}/output/tonynv-${distro}.qcow2"

    echo "  Building ${distro} image..."
    local build_log="/tmp/test-${distro}-build.log"
    if "${SCRIPT_DIR}/gen_tonynv_image.sh" --distro "$distro" --passwd "$TEST_PASSWD" > "$build_log" 2>&1; then
        pass "${distro}: image build succeeded"
    else
        fail "${distro}: image build failed" "see ${build_log}"
        return 1
    fi

    if [[ -f "$output" ]]; then
        pass "${distro}: output file exists"
    else
        fail "${distro}: output file missing"
        return 1
    fi

    if qemu-img info "$output" 2>/dev/null | grep -q "qcow2"; then
        pass "${distro}: valid qcow2 format"
    else
        fail "${distro}: not a valid qcow2"
        return 1
    fi
}

# -------------------------------------------------------
# Inspect tests — read injected files with virt-cat
# -------------------------------------------------------
test_inspect() {
    local distro="$1"
    local image="${SCRIPT_DIR}/output/tonynv-${distro}.qcow2"

    [[ -f "$image" ]] || { fail "${distro}: no image to inspect"; return 1; }

    # Read user-data from the image
    local userdata
    userdata="$(virt-cat -a "$image" /var/lib/cloud/seed/nocloud/user-data 2>/dev/null)" || {
        fail "${distro}: could not read user-data from image"
        return 1
    }
    pass "${distro}: cloud-init user-data present"

    # Read meta-data
    if virt-cat -a "$image" /var/lib/cloud/seed/nocloud/meta-data &>/dev/null; then
        pass "${distro}: cloud-init meta-data present"
    else
        fail "${distro}: cloud-init meta-data missing"
    fi

    # --- user-data content checks ---

    if echo "$userdata" | grep -q "name: tonynv"; then
        pass "${distro}: tonynv user defined"
    else
        fail "${distro}: tonynv user missing"
    fi

    if echo "$userdata" | grep -q "NOPASSWD:ALL"; then
        pass "${distro}: tonynv has sudo"
    else
        fail "${distro}: tonynv sudo missing"
    fi

    if echo "$userdata" | grep -q "tonynv/dotfiles"; then
        pass "${distro}: dotfiles clone present"
    else
        fail "${distro}: dotfiles clone missing"
    fi

    if echo "$userdata" | grep -q "tonynv_setup.sh"; then
        pass "${distro}: tonynv_setup.sh present"
    else
        fail "${distro}: tonynv_setup.sh missing"
    fi

    if echo "$userdata" | grep -q "cd /root"; then
        pass "${distro}: setup runs for root"
    else
        fail "${distro}: root setup missing"
    fi

    if echo "$userdata" | grep -q "su - tonynv"; then
        pass "${distro}: setup runs for tonynv"
    else
        fail "${distro}: tonynv setup missing"
    fi

    if echo "$userdata" | grep -q "/etc/issue"; then
        pass "${distro}: /etc/issue write_files entry"
    else
        fail "${distro}: /etc/issue write_files missing"
    fi

    if echo "$userdata" | grep -q "/etc/motd"; then
        pass "${distro}: /etc/motd write_files entry"
    else
        fail "${distro}: /etc/motd write_files missing"
    fi

    if echo "$userdata" | grep -q "tonynv/image"; then
        pass "${distro}: banner URL in user-data"
    else
        fail "${distro}: banner URL missing"
    fi

    if echo "$userdata" | grep -q "root:${TEST_PASSWD}"; then
        pass "${distro}: root password set"
    else
        fail "${distro}: root password missing"
    fi

    if echo "$userdata" | grep -q "tonynv:${TEST_PASSWD}"; then
        pass "${distro}: tonynv password set"
    else
        fail "${distro}: tonynv password missing"
    fi

    if echo "$userdata" | grep -q "console=ttyS0"; then
        pass "${distro}: serial console kernel parameter"
    else
        fail "${distro}: serial console kernel parameter missing"
    fi

    if echo "$userdata" | grep -q "serial-getty@ttyS0"; then
        pass "${distro}: serial-getty service enabled"
    else
        fail "${distro}: serial-getty service missing"
    fi
}

# -------------------------------------------------------
# Boot test — QEMU with KVM, check serial console output
# -------------------------------------------------------
test_boot() {
    local distro="$1"
    local image="${SCRIPT_DIR}/output/tonynv-${distro}.qcow2"

    [[ -f "$image" ]] || { fail "${distro}: no image to boot"; return 1; }

    # Create an overlay so the template image stays clean
    local overlay="/tmp/test-${distro}-overlay.qcow2"
    local log="/tmp/test-${distro}-boot.log"
    rm -f "$overlay" "$log"

    qemu-img create -f qcow2 -b "$image" -F qcow2 "$overlay" >/dev/null 2>&1

    local qemu_args=(
        -machine q35
        -m 1024
        -smp 2
        -nographic
        -no-reboot
        -drive "file=${overlay},format=qcow2,if=virtio"
        -nic bridge,br=br-vlan200,model=virtio
        -object rng-random,filename=/dev/urandom,id=rng0
        -device virtio-rng-pci,rng=rng0
    )

    if [[ -r /dev/kvm ]]; then
        qemu_args+=(-enable-kvm -cpu host)
    fi

    echo "  Booting ${distro} (timeout 180s)..."
    timeout 180 qemu-system-x86_64 "${qemu_args[@]}" > "$log" 2>&1 || true

    if grep -q "login:" "$log" 2>/dev/null || grep -q "login :" "$log" 2>/dev/null; then
        pass "${distro}: boots to login prompt"
    else
        fail "${distro}: did not reach login prompt" "see ${log}"
    fi

    if grep -q "tonynv/image" "$log" 2>/dev/null; then
        pass "${distro}: login banner shows tonynv/image"
    else
        fail "${distro}: login banner missing" "see ${log}"
    fi

    rm -f "$overlay"
}

# -------------------------------------------------------
# Network test — boot with networking, login, check IP
# -------------------------------------------------------
test_network() {
    local distro="$1"
    local image="${SCRIPT_DIR}/output/tonynv-${distro}.qcow2"

    [[ -f "$image" ]] || { fail "${distro}: no image for network test"; return 1; }

    local overlay="/tmp/test-${distro}-net-overlay.qcow2"
    local log="/tmp/test-${distro}-net.log"
    local pipe="/tmp/test-${distro}-net.pipe"
    rm -f "$overlay" "$log" "$pipe"

    qemu-img create -f qcow2 -b "$image" -F qcow2 "$overlay" >/dev/null 2>&1
    mkfifo "$pipe"

    local qemu_args=(
        -machine q35
        -m 1024
        -smp 2
        -nographic
        -no-reboot
        -drive "file=${overlay},format=qcow2,if=virtio"
        -nic bridge,br=br-vlan200,model=virtio
        -object rng-random,filename=/dev/urandom,id=rng0
        -device virtio-rng-pci,rng=rng0
    )

    [[ -r /dev/kvm ]] && qemu_args+=(-enable-kvm -cpu host)

    echo "  Booting ${distro} with networking (timeout 240s)..."
    qemu-system-x86_64 "${qemu_args[@]}" < "$pipe" > "$log" 2>&1 &
    local qemu_pid=$!

    # Hold the pipe open for writing
    exec 3>"$pipe"

    # Poll for login prompt
    local waited=0
    local max_wait=200
    while [[ $waited -lt $max_wait ]]; do
        if ! kill -0 "$qemu_pid" 2>/dev/null; then
            break
        fi
        if grep -q "login:" "$log" 2>/dev/null || grep -q "login :" "$log" 2>/dev/null; then
            break
        fi
        sleep 5
        ((waited += 5))
    done

    if [[ $waited -ge $max_wait ]]; then
        fail "${distro}: network test timed out waiting for login"
        exec 3>&-
        kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null || true
        rm -f "$overlay" "$pipe"
        return 1
    fi

    # Login and check IP
    sleep 2
    echo "tonynv" >&3
    sleep 3
    echo "$TEST_PASSWD" >&3
    sleep 5
    echo "ip -4 addr show" >&3
    sleep 5

    # Shutdown
    echo "sudo poweroff" >&3
    sleep 5
    exec 3>&-
    kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null || true

    # Strip ANSI escape codes, then check for an IP on 10.200.0.0/24 (br-vlan200)
    local clean_log
    clean_log="$(sed 's/\x1b\[[0-9;]*m//g' "$log")"

    if echo "$clean_log" | grep -oE "10\.200\.[0-9]+\.[0-9]+" | head -1 | grep -q "10\.200\."; then
        local ip_found
        ip_found="$(echo "$clean_log" | grep -oE "10\.200\.[0-9]+\.[0-9]+(/[0-9]+)?" | head -1)"
        pass "${distro}: VM obtained IP address (${ip_found}) from br-vlan200"
    else
        fail "${distro}: no 10.200.x.x IP address from br-vlan200" "see ${log}"
    fi

    rm -f "$overlay" "$pipe"
}

# -------------------------------------------------------
# Main
# -------------------------------------------------------
main() {
    echo "==========================================="
    echo " gen_tonynv_image.sh — Test Suite"
    echo "==========================================="

    # Verify required tools
    for cmd in virt-customize virt-cat qemu-system-x86_64 qemu-img; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: ${cmd} not found. Install libguestfs-tools and qemu."
            exit 1
        fi
    done

    for distro in "${DISTROS[@]}"; do
        echo ""
        echo "=== ${distro} ==="

        echo ""
        echo "[Build]"
        test_build "$distro" || { echo "  Skipping remaining tests for ${distro}"; continue; }

        echo ""
        echo "[Inspect]"
        test_inspect "$distro"

        echo ""
        echo "[Boot]"
        test_boot "$distro"

        echo ""
        echo "[Network]"
        test_network "$distro"
    done

    echo ""
    echo "==========================================="
    echo " Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
    echo "==========================================="

    [[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"
