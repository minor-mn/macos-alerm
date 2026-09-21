#!/bin/bash
# LaunchAgent の登録を解除する
set -euo pipefail

LABEL="local.macos-alerm"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "解除完了: $LABEL"
