#!/bin/bash

# Add Node to NixOS Cluster Script
# This script automates the process of adding a new node to the cluster

set -e

# Configuration
NODE_NAME="${1:-}"
GITHUB_REPO="git@github.com:Selvian-ai/forge.git"
KEY_NAME="$NODE_NAME-github"

if [ -z "$NODE_NAME" ]; then
    echo "❌ Usage: $0 <node-name>"
    echo ""
    echo "Examples:"
    echo "  $0 vega"
    echo "  $0 rigel"
    echo ""
    echo "Make sure you have:"
    echo "1. NixOS installed on the node"
    echo "2. Internet connectivity"
    echo "3. 1Password CLI access"
    exit 1
fi

echo "🚀 Adding node '$NODE_NAME' to the NixOS cluster..."
echo "=================================================="

# Step 1: Install git
echo ""
echo "1️⃣  Installing git..."
nix --extra-experimental-features nix-command --extra-experimental-features flakes profile install "github:NixOS/nixpkgs/nixos-24.11#git"
echo "✅ Git installed"

# Step 2: Install jq
echo ""
echo "2️⃣  Installing jq..."
nix --extra-experimental-features nix-command --extra-experimental-features flakes profile install "nixpkgs#jq"
echo "✅ jq installed"

# Step 3: Add 1Password CLI
echo ""
echo "3️⃣  Installing 1Password CLI..."
export NIXPKGS_ALLOW_UNFREE=1
nix --extra-experimental-features nix-command --extra-experimental-features flakes profile install --impure github:NixOS/nixpkgs/nixos-24.11#_1password-cli
echo "✅ 1Password CLI installed"

# Step 4: Sign in to 1Password
echo ""
echo "4️⃣  Signing in to 1Password..."
echo "Please sign in to 1Password when prompted:"
eval $(op signin)
echo "✅ Signed in to 1Password"

# Step 5: Get private key from 1Password
echo ""
echo "5️⃣  Getting private key from 1Password..."
echo "Retrieving key: $KEY_NAME"
mkdir -p ~/.ssh
op item get "$KEY_NAME" --field "private key" --format json --reveal | jq -r '.value' > ~/.ssh/$KEY_NAME
chmod 600 ~/.ssh/$KEY_NAME
echo "✅ Private key saved to ~/.ssh/$KEY_NAME"

# Step 6: Start SSH agent and configure SSH
echo ""
echo "6️⃣  Configuring SSH..."
eval "$(ssh-agent -s)"

# Create SSH config if it doesn't exist
if [ ! -f ~/.ssh/config ]; then
    touch ~/.ssh/config
    chmod 600 ~/.ssh/config
fi

# Add GitHub configuration to SSH config
if ! grep -q "Host github.com" ~/.ssh/config; then
    cat >> ~/.ssh/config << EOF

Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/$KEY_NAME
  IdentitiesOnly yes
EOF
    echo "✅ SSH config updated"
else
    echo "ℹ️  SSH config already contains GitHub configuration"
fi

# Add the key to SSH agent
ssh-add ~/.ssh/$KEY_NAME
echo "✅ SSH key added to agent"

# Step 7: Clone the forge repository
echo ""
echo "7️⃣  Cloning the forge repository..."
if [ -d "forge" ]; then
    echo "ℹ️  Forge directory already exists, pulling latest changes..."
    cd forge
    git pull
else
    git clone $GITHUB_REPO
    cd forge
fi
echo "✅ Repository cloned/updated"

# Step 8: Get the rest of the keys
echo ""
echo "8️⃣  Getting additional keys and configuration..."
cd nixos-cluster/server-scripts
./keys_and_config.sh "$NODE_NAME"
echo "✅ Keys and configuration retrieved"

# Step 9: Setup the flake
echo ""
echo "9️⃣  Setting up the NixOS flake..."
cd ../configuration
sudo nixos-rebuild switch --flake .#$NODE_NAME
echo "✅ NixOS flake configured"

echo ""
echo "🎉 Node '$NODE_NAME' has been successfully added to the cluster!"
echo ""
echo "Next steps:"
echo "1. Verify the node is working correctly"
echo "2. Check that all services are running"
echo "3. Update cluster documentation if needed"
echo ""
echo "To check the node status:"
echo "  sudo nixos-rebuild dry-activate --flake .#$NODE_NAME" 