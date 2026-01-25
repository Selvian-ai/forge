#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Usage:  ./setup-ssh-keys.sh <node-name>   (e.g. ./setup-ssh-keys.sh vega)
###############################################################################
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <node-name>"
  exit 1
fi
NODE_NAME="$1"

# ─ Cluster map ───────────────────────────────────────────────────────────────
CLUSTER=(vega rigel arcturus)
declare -A NODE_IP=(
  [vega]=10.10.10.5
  [rigel]=10.10.10.6
  [arcturus]=10.10.10.21
)
[[ -z "${NODE_IP[$NODE_NAME]:-}" ]] && { echo "❌ Unknown node"; exit 1; }

# ─ Require deps ──────────────────────────────────────────────────────────────
for cmd in op jq ssh-keyscan awk sed; do
  command -v "$cmd" >/dev/null || { echo "❌ Missing dependency: $cmd"; exit 1; }
done

# ─ 1 – Ensure 1Password session ─────────────────────────────────────────────
if ! op whoami &>/dev/null; then
  echo "🔐  1Password CLI not signed in — signing in…"
  eval "$(op signin --account https://my.1password.com)"
  echo "✅  Signed in."
fi

# ─ 2 – Prepare ~/.ssh  (private keys) ───────────────────────────────────────
sudo install -d -m 700 ~/.ssh

# ─ 3 – Public-key dir  /var/lib/nixos-cluster/keys ────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
KEYS_DIR="/var/lib/nixos-cluster/keys"
sudo install -d -m 755 "$KEYS_DIR"

# Helper: fetch a field from an item
fetch_field () {
  local item="$1" field="$2"
  op item get "$item" --field "$field" --reveal
}

# Helper: extract public key from private key
fetch_public_key () {
  local item="$1"
  op item get "$item" --field "private key" --reveal | ssh-keygen -y -f /dev/stdin
}

# ─ 4 – Fetch *this node’s* keys (priv & pub) ────────────────────────────────
for KEY_TYPE in adminuser github intracom; do
  ITEM="${NODE_NAME}-${KEY_TYPE}"
  PRIV_PATH="$HOME/.ssh/${ITEM}"
  PUB_PATH="${KEYS_DIR}/${ITEM}.pub"

  echo "🔑  Fetching '${ITEM}'…"
  fetch_field "$ITEM" "private key" >"$PRIV_PATH"
  chmod 600 "$PRIV_PATH"
  fetch_public_key "$ITEM" >"$PUB_PATH"
  chmod 644 "$PUB_PATH"
done

# ─ 5 – Fetch *peers’* intracom.pub (for server-side auth) ───────────────────
for PEER in "${CLUSTER[@]}"; do
  [[ $PEER == "$NODE_NAME" ]] && continue
  ITEM="${PEER}-intracom"
  PUB_PATH="${KEYS_DIR}/${ITEM}.pub"
  echo "📥  Fetching peer pubkey '${ITEM}'…"
  fetch_public_key "$ITEM" >"$PUB_PATH"
  chmod 644 "$PUB_PATH"
done

# ─ 6 – Generate ssh_known_hosts for the cluster ─────────────────────────────
KNOWN_HOSTS="${KEYS_DIR}/ssh_known_hosts"
: >"$KNOWN_HOSTS"

echo "🧾  Building ssh_known_hosts at ${KNOWN_HOSTS}…"
for HOST in "${CLUSTER[@]}"; do
  ip="${NODE_IP[$HOST]}"
  # Prefer ed25519 host keys
  if scan=$(ssh-keyscan -T 3 -t ed25519 "$ip" 2>/dev/null); then
    # Convert "IP KEYTYPE KEY" -> "host,IP KEYTYPE KEY"
    echo "$scan" \
      | awk -v h="$HOST" -v ip="$ip" '{print h","ip" "$2" "$3}' >>"$KNOWN_HOSTS"
  else
    echo "⚠️   Could not ssh-keyscan $HOST ($ip). Skipping."
  fi
done
sudo chmod 644 "$KNOWN_HOSTS"


# ─ 7 – Generate ~/.ssh/config (outbound shortcuts) ──────────────────────────
CONFIG="$HOME/.ssh/config"
: >"$CONFIG"

cat >>"$CONFIG" <<EOF
# SSH config generated for ${NODE_NAME}

Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/${NODE_NAME}-github
  IdentitiesOnly yes

# Self (admin login)
Host ${NODE_NAME}
  HostName ${NODE_IP[$NODE_NAME]}
  User admin
  IdentityFile ~/.ssh/${NODE_NAME}-adminuser
  IdentitiesOnly yes
  UserKnownHostsFile ${KNOWN_HOSTS}
  StrictHostKeyChecking yes
EOF

for PEER in "${CLUSTER[@]}"; do
  [[ $PEER == "$NODE_NAME" ]] && continue
  cat >>"$CONFIG" <<EOF

# Peer ${PEER} over intracom (no root)
Host ${PEER}
  HostName ${NODE_IP[$PEER]}
  User intracom
  IdentityFile ~/.ssh/${NODE_NAME}-intracom
  IdentitiesOnly yes
  UserKnownHostsFile ${KNOWN_HOSTS}
  StrictHostKeyChecking yes
EOF
done

chmod 600 "$CONFIG"
# Ensure user owns ~/.ssh
chown -R "$(id -u)":"$(id -g)" "$HOME/.ssh"

echo "✅  SSH keys, ssh_known_hosts, and config set up for '${NODE_NAME}'."

# ─ 8 – Flake reminder ───────────────────────────────────────────────────────
cat <<EOF

📝  In flake.nix:

  inputs.keys = {
    url   = "path:/var/lib/nixos-cluster/keys";
    flake = false;
  };

And in your module, ensure:
  - admin/root authorized only with ${NODE_NAME}-adminuser.pub
  - intracom authorized with *peers’* intracom.pub
  - /etc/ssh/ssh_known_hosts sourced from inputs.keys/ssh_known_hosts

After changing any key:
  sudo nixos-rebuild switch --flake .#${NODE_NAME}

EOF