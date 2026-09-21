# macos-alerm

macOS 用の常駐型アラームデーモン。YAML で書いたスケジュールを監視し、
予定の指定分前(例: 1分前)になるとアラーム音を鳴らしてメッセージを画面表示します。

- Swift 製(YAMLパースは [Yams](https://github.com/jpsim/Yams))
- launchd の LaunchAgent として常駐: ログイン時に自動起動、異常終了時は自動再起動
- `schedule.yaml` は10分毎に再読み込み(ファイル編集は約15秒以内に反映)
- 音は `afplay`、画面表示は `osascript`(ダイアログ or 通知センター)
- 発火済み記録を `~/.local/state/macos-alerm/fired.json` に保存し、
  デーモン再起動時の二重発火を防止

## 環境構築

- macOS 13 以降
- Xcode(または Command Line Tools)と Swift 5.9 以上

  ```sh
  xcode-select --install   # Xcode 未インストールの場合
  swift --version          # ツールチェーンの確認
  ```

- 初回ビルド時はネットワーク接続が必要(Swift Package Manager が Yams を取得)

## ビルド手順

`schedule.yaml` は個人の予定を含むため git 管理外です。リポジトリには
`schedule.example.yaml` のみコミットされているので、まずこれをコピーして
自分用の `schedule.yaml` を作成してください(ファイルが無い場合は
`install.sh` が自動でコピーします):

```sh
cp schedule.example.yaml schedule.yaml   # 初回のみ
swift build -c release
```

バイナリは `.build/release/macos-alerm` に生成されます。

常駐登録せずフォアグラウンドで試す場合:

```sh
.build/release/macos-alerm schedule.yaml
```

`Ctrl+C` で停止します。ログは標準出力に出ます。

## 実行(常駐)手順

まず `schedule.yaml` を編集してから(書き方は後述):

```sh
./install.sh
```

このスクリプトは以下を行います:

1. `schedule.yaml` が無ければ `schedule.example.yaml` からコピーして作成
2. リリースバイナリのビルド(`swift build -c release`)
3. `~/Library/LaunchAgents/local.macos-alerm.plist` の生成
4. `launchctl bootstrap` で登録(即時起動し、以降はログイン毎に自動起動)

運用メモ:

- ログ: `~/Library/Logs/macos-alerm.log`
- 状態確認: `launchctl print gui/$(id -u)/local.macos-alerm`
- 手動再起動: `launchctl kickstart -k gui/$(id -u)/local.macos-alerm`
- スケジュール変更は `schedule.yaml` を保存するだけで自動反映されます

## 終了手順

常駐デーモンを停止するには:

```sh
launchctl bootout gui/$(id -u)/local.macos-alerm
```

LaunchAgent の登録自体は残るため、次回ログイン時には再び自動起動します。
すぐに再開したい場合:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.macos-alerm.plist
```

ログイン時の自動起動も止めたい場合(登録は残したまま):

```sh
launchctl bootout gui/$(id -u)/local.macos-alerm   # いま動いていれば停止
launchctl disable gui/$(id -u)/local.macos-alerm   # ログイン時に起動しない
```

自動起動を元に戻す場合:

```sh
launchctl enable gui/$(id -u)/local.macos-alerm
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.macos-alerm.plist
```

(フォアグラウンド実行中の場合は `Ctrl+C` で終了します。)

## アンインストール

```sh
./uninstall.sh
```

デーモンを停止して LaunchAgent の登録を解除し、plist を削除します。
以降はログイン時にも起動しません。ビルド成果物と `schedule.yaml` は
そのまま残ります。

## schedule.yaml の書き方

```yaml
defaults:
  before_minutes: 1                          # 予定の何分前に鳴らすか
  sound: /System/Library/Sounds/Glass.aiff   # アラーム音
  repeat_sound: 3                            # 音を繰り返す回数
  display: dialog                            # dialog(画面中央) | notification(通知センター)

events:
  # 繰り返し予定: at に "HH:MM"。weekdays を省略すると毎日
  - title: 朝会
    message: 10:00 から朝会です
    at: "10:00"
    weekdays: [mon, tue, wed, thu, fri]      # 日本語 [月, 火, ...] も可

  # 単発予定: at に "YYYY-MM-DD HH:MM"
  - title: 通院
    message: 病院へ出発
    at: "2026-09-25 14:30"
    before_minutes: 10
    sound: /System/Library/Sounds/Sosumi.aiff
```

各イベントで `before_minutes` / `sound` / `repeat_sound` / `display` を個別に
上書きできます(省略時は `defaults` の値)。

アラーム音は `/System/Library/Sounds/` にある `.aiff`(Glass, Sosumi, Ping,
Submarine など)がそのまま使えるほか、任意の音声ファイルのパスも指定できます。
