#!/bin/sh
# ocicl-bot: install and run
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/ocicl/ocicl-bot/main/install-and-run.sh | sh
#
# Prerequisites:
#   - podman (or docker)
#   - GitHub App private key at ~/.local/etc/ocicl-bot/app-key.pem

set -e

CONFIG_DIR="${OCICL_BOT_CONFIG:-$HOME/.local/etc/ocicl-bot}"
DATA_DIR="${OCICL_BOT_DATA:-$HOME/.local/share/ocicl-bot}"
ADMIN_DIR="${OCICL_ADMIN_HOME:-$HOME/ocicl-admin}"
IMAGE="ghcr.io/ocicl/ocicl-bot:latest"

# Check for Gemini API key
if [ -z "$GEMINI_API_KEY" ]; then
  if [ -f "$CONFIG_DIR/gemini-api-key" ]; then
    GEMINI_API_KEY=$(cat "$CONFIG_DIR/gemini-api-key")
  else
    echo "Error: GEMINI_API_KEY not set and $CONFIG_DIR/gemini-api-key not found" >&2
    exit 1
  fi
fi

# Detect container runtime
if command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
elif command -v docker >/dev/null 2>&1; then
  RUNTIME=docker
else
  echo "Error: podman or docker required" >&2
  exit 1
fi

# Create dirs
mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$ADMIN_DIR"

# Check for app key
if [ ! -f "$CONFIG_DIR/app-key.pem" ]; then
  echo "Error: GitHub App private key not found at $CONFIG_DIR/app-key.pem" >&2
  echo "" >&2
  echo "Setup:" >&2
  echo "  1. Create the ocicl-bot GitHub App on the ocicl org" >&2
  echo "  2. Generate a private key and save it:" >&2
  echo "     cp ~/Downloads/ocicl-bot.*.pem $CONFIG_DIR/app-key.pem" >&2
  echo "     chmod 600 $CONFIG_DIR/app-key.pem" >&2
  exit 1
fi

# Pull latest image
echo "Pulling $IMAGE..."
$RUNTIME pull "$IMAGE" 2>/dev/null || {
  # Image not published yet -- build locally
  echo "Image not in registry, building locally..."
  TMPDIR=$(mktemp -d)
  git clone --depth 1 https://github.com/ocicl/ocicl-bot.git "$TMPDIR"
  $RUNTIME build -t ocicl-bot -f "$TMPDIR/Containerfile" "$TMPDIR"
  rm -rf "$TMPDIR"
  IMAGE="ocicl-bot"
}

# Run
echo "Running ocicl-bot..."
exec $RUNTIME run --rm \
  -e "GEMINI_API_KEY=$GEMINI_API_KEY" \
  -v "$CONFIG_DIR":/config \
  -v "$DATA_DIR":/data \
  -v "$ADMIN_DIR":/ocicl-admin \
  "$IMAGE"
