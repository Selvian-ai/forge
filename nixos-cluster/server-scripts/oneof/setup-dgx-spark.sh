#!/bin/bash

# Setup DGX Spark Node Script
# This script automates the process of setting up the DGX spark node
# Run this script ON the DGX spark machine after initial OS installation

set -e

# Configuration
NODE_NAME="spark"
NODE_IP="10.10.10.124"
GITHUB_REPO="git@github.com:claudiordgz/forge.git"
GITHUB_KEY_NAME="$NODE_NAME-github"

echo "🚀 Setting up DGX node '$NODE_NAME'..."
echo "=================================================="

# Step 1: Install curl and basic tools
echo ""
echo "1️⃣  Installing basic dependencies..."
sudo apt-get update
sudo apt-get install -y curl jq openssh-client git
echo "✅ Basic tools installed"

# Step 2: Install 1Password CLI
echo ""
echo "2️⃣  Installing 1Password CLI..."
if ! command -v op &>/dev/null; then
    curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
        sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | \
        sudo tee /etc/apt/sources.list.d/1password.list
    sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/
    curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol | \
        sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol
    sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
    curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
        sudo gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
    sudo apt-get update
    sudo apt-get install -y 1password-cli
    echo "✅ 1Password CLI installed"
else
    echo "ℹ️  1Password CLI already installed"
fi

# Step 3: Sign in to 1Password
echo ""
echo "3️⃣  Signing in to 1Password..."
echo "Please sign in to 1Password when prompted:"
eval $(op signin)
echo "✅ Signed in to 1Password"

# Step 4: Get GitHub private key from 1Password
echo ""
echo "4️⃣  Getting GitHub private key from 1Password..."
echo "Retrieving key: $GITHUB_KEY_NAME from vault 'Machines'"
mkdir -p ~/.ssh
op item get "$GITHUB_KEY_NAME" --vault "Machines" --field "private key" --format json --reveal | jq -r '.value' > ~/.ssh/$GITHUB_KEY_NAME
chmod 600 ~/.ssh/$GITHUB_KEY_NAME
echo "✅ Private key saved to ~/.ssh/$GITHUB_KEY_NAME"

# Step 5: Start SSH agent and configure SSH
echo ""
echo "5️⃣  Configuring SSH..."
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
  IdentityFile ~/.ssh/$GITHUB_KEY_NAME
  IdentitiesOnly yes
EOF
    echo "✅ SSH config updated"
else
    echo "ℹ️  SSH config already contains GitHub configuration"
fi

# Add the key to SSH agent
ssh-add ~/.ssh/$GITHUB_KEY_NAME
echo "✅ SSH key added to agent"

# Step 6: Clone the forge repository
echo ""
echo "6️⃣  Cloning the forge repository..."
if [ -d "forge" ]; then
    echo "ℹ️  Forge directory already exists, pulling latest changes..."
    cd forge
    git pull
else
    git clone $GITHUB_REPO
    cd forge
fi
echo "✅ Repository cloned/updated"

# Step 7: Get the rest of the keys and setup SSH
echo ""
echo "7️⃣  Getting additional keys and setting up SSH access..."

# Fetch remaining keys from 1Password
fetch_field() {
    local item="$1" field="$2"
    op item get "$item" --vault "Machines" --field "$field" --reveal
}

fetch_public_key() {
    local item="$1"
    # For SSH keys, get the private key and extract the public key from it
    op item get "$item" --vault "Machines" --field "private key" --reveal | ssh-keygen -y -f /dev/stdin
}

for KEY_TYPE in adminuser intracom; do
    ITEM_NAME="${NODE_NAME}-${KEY_TYPE}"
    PRIV_PATH="$HOME/.ssh/${ITEM_NAME}"
    PUB_PATH="$HOME/.ssh/${ITEM_NAME}.pub"
    
    echo "📥 Fetching ${ITEM_NAME}..."
    fetch_field "$ITEM_NAME" "private key" > "$PRIV_PATH"
    chmod 600 "$PRIV_PATH"
    fetch_public_key "$ITEM_NAME" > "$PUB_PATH"
    chmod 644 "$PUB_PATH"
done

echo "✅ All keys retrieved"

# Step 8: Setup authorized_keys
echo ""
echo "8️⃣  Setting up authorized_keys for remote access..."

# Backup existing authorized_keys
if [ -f ~/.ssh/authorized_keys ]; then
    cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.backup.$(date +%Y%m%d_%H%M%S)
fi

# Add the adminuser public key
cat "$HOME/.ssh/${NODE_NAME}-adminuser.pub" >> ~/.ssh/authorized_keys

# Add intracom keys from peer nodes
CLUSTER=(vega rigel arcturus)
for PEER in "${CLUSTER[@]}"; do
    PEER_KEY="${PEER}-intracom"
    echo "📥 Fetching peer key ${PEER_KEY}..."
    PEER_PUB=$(fetch_public_key "$PEER_KEY")
    echo "$PEER_PUB" >> ~/.ssh/authorized_keys
done

chmod 600 ~/.ssh/authorized_keys
echo "✅ Authorized keys configured"

# Step 9: Complete SSH config with peer nodes
echo ""
echo "9️⃣  Completing SSH configuration with peer nodes..."

# Define peer IPs
declare -A NODE_IP_MAP=(
    [vega]=10.10.10.5
    [rigel]=10.10.10.6
    [arcturus]=10.10.10.21
)

# Add self entry
if ! grep -q "Host $NODE_NAME" ~/.ssh/config; then
    cat >> ~/.ssh/config <<EOF

# Self (admin login)
Host ${NODE_NAME}
  HostName ${NODE_IP}
  User $(whoami)
  IdentityFile ~/.ssh/${NODE_NAME}-adminuser
  IdentitiesOnly yes
EOF
fi

# Add peer entries
for PEER in "${CLUSTER[@]}"; do
    if ! grep -q "Host $PEER" ~/.ssh/config; then
        cat >> ~/.ssh/config <<EOF

# Peer ${PEER}
Host ${PEER}
  HostName ${NODE_IP_MAP[$PEER]}
  User intracom
  IdentityFile ~/.ssh/${NODE_NAME}-intracom
  IdentitiesOnly yes
EOF
    fi
done

echo "✅ SSH config completed"

echo ""
echo "🎉 DGX node '$NODE_NAME' has been successfully set up!"
echo ""
echo "Summary:"
echo "  ✅ 1Password CLI installed and configured"
echo "  ✅ SSH keys fetched and installed"
echo "  ✅ Authorized keys configured for remote access"
echo "  ✅ SSH config created for GitHub and cluster peers"
echo "  ✅ Forge repository cloned"
echo ""
echo "Next steps:"
echo "1. Test SSH access from peers: ssh spark"
echo "2. Test GitHub access: ssh -T git@github.com"
echo "3. Install NVIDIA drivers and CUDA toolkit if needed"
echo "4. Install Docker and nvidia-docker for containerized workloads"
echo "5. Configure any DGX-specific monitoring/management tools"
echo ""
echo "To test connectivity from a peer node:"
echo "  ssh spark"
