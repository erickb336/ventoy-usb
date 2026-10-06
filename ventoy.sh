#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" = Darwin ]; then
    exec /bin/bash "$(dirname "$0")/macos/ventoy-mac.sh" "$@"
fi

echo "🚀 Ventoy USB Manager"
echo "Choose an option:"
echo "1. Install Ventoy on a USB drive"
echo "2. Add ISO files to existing Ventoy USB"
echo

read -rp "Enter choice (1 or 2): " CHOICE

case $CHOICE in
    1)
        echo "Starting Ventoy installation..."
        ./ventoy-install.sh "$@"
        ;;
    2)
        echo "Starting ISO addition..."
        ./ventoy-add-isos.sh "$@"
        ;;
    *)
        echo "❌ Invalid choice. Please run again and choose 1 or 2."
        exit 1
        ;;
esac