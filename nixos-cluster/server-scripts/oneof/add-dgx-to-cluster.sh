#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Update NixOS cluster nodes to add DGX spark to known hosts and SSH config
# 
# Run this script from your local machine to update the cluster configuration
###############################################################################

NODE_NAME="spark"
NODE_IP="10.10.10.124"

echo "🔧  Adding DGX ${NODE_NAME} to cluster configuration"
echo ""

# ─ Cluster nodes ─────────────────────────────────────────────────────────────
CLUSTER_NODES=(vega rigel arcturus)

echo "This script will help you add ${NODE_NAME} to the SSH configuration"
echo "of the existing NixOS cluster nodes."
echo ""
echo "Steps needed:"
echo "  1. Update each node's SSH known_hosts"
echo "  2. Update each node's SSH config"
echo "  3. Test connectivity"
echo ""

# ─ Generate known_hosts entry ────────────────────────────────────────────────
echo "📋  Scanning ${NODE_NAME} SSH host key..."
KNOWN_HOST_ENTRY=$(ssh-keyscan -T 3 -t ed25519 "$NODE_IP" 2>/dev/null | \
    awk -v h="$NODE_NAME" -v ip="$NODE_IP" '{print h","ip" "$2" "$3}')

if [ -z "$KNOWN_HOST_ENTRY" ]; then
    echo "❌ Could not scan ${NODE_NAME} at ${NODE_IP}"
    echo "   Make sure the DGX is accessible and SSH is running"
    exit 1
fi

echo "✅  Got host key: ${KNOWN_HOST_ENTRY}"
echo ""

# ─ Instructions for each node ────────────────────────────────────────────────
cat <<EOF
Manual steps to perform on each NixOS node (${CLUSTER_NODES[*]}):

1. SSH into each node as admin:
   $ ssh vega  # (or rigel, arcturus)

2. Add the following line to /var/lib/nixos-cluster/keys/ssh_known_hosts:
   ${KNOWN_HOST_ENTRY}

3. Add the following to your SSH config (/root/.ssh/config or ~/.ssh/config):

Host ${NODE_NAME}
  HostName ${NODE_IP}
  User <username-on-dgx>
  IdentityFile ~/.ssh/<nodename>-intracom
  IdentitiesOnly yes
  StrictHostKeyChecking yes

4. Test connectivity:
   $ ssh ${NODE_NAME}

5. If using NixOS configuration management, you may want to add ${NODE_NAME}
   to your cluster map and regenerate known_hosts.

EOF

# ─ Optional: Direct update if running on a cluster node ─────────────────────
if [ -f /etc/nixos/configuration.nix ] && [ -d /var/lib/nixos-cluster/keys ]; then
    echo "🔍  Detected NixOS system with cluster configuration"
    read -p "Add ${NODE_NAME} to ssh_known_hosts now? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        KNOWN_HOSTS="/var/lib/nixos-cluster/keys/ssh_known_hosts"
        if [ -f "$KNOWN_HOSTS" ]; then
            echo "$KNOWN_HOST_ENTRY" | sudo tee -a "$KNOWN_HOSTS" >/dev/null
            echo "✅  Added to $KNOWN_HOSTS"
        else
            echo "❌ $KNOWN_HOSTS not found"
        fi
    fi
fi

echo ""
echo "📝  Note: Since ${NODE_NAME} is a DGX and not NixOS, you'll need to"
echo "    manage its SSH configuration manually or with other tools."
