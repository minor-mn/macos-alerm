#!/bin/bash
# ビルドして LaunchAgent として登録する(ログイン時自動起動+常駐)
set -euo pipefail
cd "$(dirname "$0")"

# schedule.yaml が無ければサンプルからコピーして作成
[ -f schedule.yaml ] || cp schedule.example.yaml schedule.yaml

swift build -c release

BIN="$(pwd)/.build/release/macos-alerm"
SCHEDULE="$(pwd)/schedule.yaml"
LABEL="local.macos-alerm"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/macos-alerm.log"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>$SCHEDULE</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

# 既に登録済みなら一度解除してから登録し直す(disable されていても有効化する)
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl enable "gui/$(id -u)/$LABEL"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "登録完了: $LABEL"
echo "ログ: $LOG"
launchctl print "gui/$(id -u)/$LABEL" | grep -E "state|pid" | head -3 || true
