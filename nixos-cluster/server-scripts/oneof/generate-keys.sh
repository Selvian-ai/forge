#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Usage:  ./generate-keys.sh <node-name>   (e.g. ./generate-keys.sh spark)
# 
# Generates SSH keys for a node, saves them to ~/code/cluster-keys,
# and uploads them to 1Password vault "Machines"
###############################################################################
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <node-name>"
  exit 1
fi
NODE_NAME="$1"

# ─ Cluster validation ────────────────────────────────────────────────────────
CLUSTER=(vega rigel arcturus spark)
if [[ ! " ${CLUSTER[@]} " =~ " ${NODE_NAME} " ]]; then
  echo "❌ Unknown node. Valid nodes: ${CLUSTER[*]}"
  exit 1
fi

# ─ Require deps ──────────────────────────────────────────────────────────────
for cmd in ssh-keygen op jq; do
  command -v "$cmd" >/dev/null || { echo "❌ Missing dependency: $cmd"; exit 1; }
done

# ─ Ensure 1Password session ─────────────────────────────────────────────────
if ! op whoami &>/dev/null; then
  echo "🔐  1Password CLI not signed in — signing in…"
  eval "$(op signin --account https://my.1password.com)"
  echo "✅  Signed in."
fi

# ─ Create keys directory ─────────────────────────────────────────────────────
KEYS_DIR="$HOME/code/cluster-keys"
mkdir -p "$KEYS_DIR"

echo "🔑  Generating SSH keys for node: ${NODE_NAME}"
echo "📁  Keys will be saved to: ${KEYS_DIR}"
echo "☁️   Keys will be uploaded to 1Password vault: Machines"
echo ""

# ─ Generate keys for each type ───────────────────────────────────────────────
for KEY_TYPE in adminuser github intracom; do
  ITEM_NAME="${NODE_NAME}-${KEY_TYPE}"
  KEY_PATH="${KEYS_DIR}/${ITEM_NAME}"
  
  echo "📝  Generating ${KEY_TYPE} key pair..."
  ssh-keygen -t ed25519 -C "${ITEM_NAME}" -f "${KEY_PATH}" -N "" -q
  
  chmod 600 "${KEY_PATH}"
  chmod 644 "${KEY_PATH}.pub"
  
  echo "✅  ${ITEM_NAME} saved to ${KEYS_DIR}/"
  
  # Read the keys
  PRIVATE_KEY=$(cat "${KEY_PATH}")
  PUBLIC_KEY=$(cat "${KEY_PATH}.pub")
  
  # Get SSH key fingerprint
  FINGERPRINT=$(ssh-keygen -lf "${KEY_PATH}.pub" | awk '{print $2}')
  
  # Create temporary JSON template for SSH Key
  TEMP_JSON=$(mktemp)
  cat > "$TEMP_JSON" <<EOF
{
  "title": "${ITEM_NAME}",
  "category": "SSH_KEY",
  "vault": {
    "name": "Machines"
  },
  "fields": [
    {
      "id": "private_key",
      "type": "CONCEALED",
      "label": "private key",
      "value": $(echo "$PRIVATE_KEY" | jq -Rs .)
    },
    {
      "id": "public_key",
      "type": "STRING",
      "label": "public key",
      "value": $(echo "$PUBLIC_KEY" | jq -Rs .)
    },
    {
      "id": "fingerprint",
      "type": "STRING",
      "label": "fingerprint",
      "value": "${FINGERPRINT}"
    }
  ]
}
EOF
  
  # Upload to 1Password in Machines vault
  echo "☁️   Uploading ${ITEM_NAME} to 1Password vault 'Machines'..."
  op item create --template "$TEMP_JSON" >/dev/null
  
  rm "$TEMP_JSON"
  
  echo "✅  ${ITEM_NAME} uploaded to 1Password"
  echo ""
done

echo "🎉  All keys generated and uploaded for ${NODE_NAME}!"
echo ""
echo "Generated files in ${KEYS_DIR}:"
ls -lh "${KEYS_DIR}/${NODE_NAME}-"*
echo ""
echo "1Password items created in vault 'Machines':"
echo "  - ${NODE_NAME}-adminuser"
echo "  - ${NODE_NAME}-github"
echo "  - ${NODE_NAME}-intracom"
