#!/bin/sh
# Run ocicl-bot in a container.
#
# Setup (one-time):
#   mkdir -p ~/.local/etc/ocicl-bot ~/.local/share/ocicl-bot
#   cp app-key.pem ~/.local/etc/ocicl-bot/
#   echo 0 > ~/.local/etc/ocicl-bot/cursor
#
# Build (one-time or after code changes):
#   podman build -t ocicl-bot -f Containerfile .
#
# Run:
#   ./ocicl-bot-run.sh

set -e

CONFIG_DIR="${OCICL_BOT_CONFIG:-$HOME/.local/etc/ocicl-bot}"
DATA_DIR="${OCICL_BOT_DATA:-$HOME/.local/share/ocicl-bot}"
ADMIN_DIR="${OCICL_ADMIN_HOME:-$HOME/ocicl-admin}"

mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$ADMIN_DIR"

exec podman run --rm \
  -v "$CONFIG_DIR":/config \
  -v "$DATA_DIR":/data \
  -v "$ADMIN_DIR":/ocicl-admin \
  ocicl-bot
