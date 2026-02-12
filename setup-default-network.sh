#!/usr/bin/env bash
#
# setup-default-network.sh - Configure libvirt default network to use br-vlan200
#
# Defines the "default" network as a bridge to br-vlan200 (10.200.0.0/24)
# so VMs get DHCP addresses from the existing network infrastructure.

set -euo pipefail

BRIDGE="br-vlan200"
NETWORK_NAME="default"

# Verify the bridge exists
if ! ip link show "$BRIDGE" &>/dev/null; then
    echo "Error: Bridge $BRIDGE does not exist on this host."
    exit 1
fi

# Remove existing default network if present
if virsh net-info "$NETWORK_NAME" &>/dev/null; then
    echo "Removing existing '$NETWORK_NAME' network..."
    virsh net-destroy "$NETWORK_NAME" 2>/dev/null || true
    virsh net-undefine "$NETWORK_NAME"
fi

# Define the default network as a bridge to br-vlan200
echo "Defining '$NETWORK_NAME' network (bridge -> $BRIDGE)..."
TMPXML="$(mktemp /tmp/net-default-XXXXXX.xml)"
trap 'rm -f "$TMPXML"' EXIT

cat > "$TMPXML" <<EOF
<network>
  <name>${NETWORK_NAME}</name>
  <forward mode="bridge"/>
  <bridge name="${BRIDGE}"/>
</network>
EOF

virsh net-define "$TMPXML"
virsh net-start "$NETWORK_NAME"
virsh net-autostart "$NETWORK_NAME"

echo ""
echo "Done. '$NETWORK_NAME' network is active and set to autostart."
echo ""
virsh net-info "$NETWORK_NAME"
echo ""
echo "VMs using '--network default' will bridge to $BRIDGE (10.200.0.0/24)"
