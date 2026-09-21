# macos-alerm

A resident alarm daemon for macOS. It watches a YAML schedule and, at the
configured lead time before each event (e.g. 1 minute before), plays an alarm
sound and shows a message on screen.

- Written in Swift (YAML parsing via [Yams](https://github.com/jpsim/Yams))
- Runs as a launchd LaunchAgent: starts at login, restarts automatically on crash
- Reloads `schedule.yaml` every 10 minutes (file edits are picked up within ~15 seconds)
- Plays sounds with `afplay`, shows messages via `osascript` (dialog or Notification Center)
- Records fired alarms in `~/.local/state/macos-alerm/fired.json` to prevent
  duplicate alarms across daemon restarts

## Requirements

- macOS 13 or later
- Xcode (or Command Line Tools) with Swift 5.9+

  ```sh
  xcode-select --install   # if you don't have Xcode installed
  swift --version          # verify the toolchain
  ```

- Network access on first build (Swift Package Manager fetches Yams)

## Build

`schedule.yaml` is not tracked by git (it contains your personal schedule).
Only `schedule.example.yaml` is committed — create your own copy from it
first (`install.sh` also does this automatically if the file is missing):

```sh
cp schedule.example.yaml schedule.yaml   # first time only
swift build -c release
```

The binary is produced at `.build/release/macos-alerm`.

To try it in the foreground without installing:

```sh
.build/release/macos-alerm schedule.yaml
```

Press `Ctrl+C` to stop. Logs are printed to stdout.

## Run as a resident daemon

First edit `schedule.yaml` (see below), then:

```sh
./install.sh
```

This script:

1. Creates `schedule.yaml` from `schedule.example.yaml` if it doesn't exist
2. Builds the release binary (`swift build -c release`)
3. Generates `~/Library/LaunchAgents/local.macos-alerm.plist`
4. Registers it with `launchctl bootstrap` (starts immediately, and again at every login)

Operational notes:

- Logs: `~/Library/Logs/macos-alerm.log`
- Check status: `launchctl print gui/$(id -u)/local.macos-alerm`
- Manual restart: `launchctl kickstart -k gui/$(id -u)/local.macos-alerm`
- Schedule changes take effect automatically — just save `schedule.yaml`

## Stop

To stop the resident daemon:

```sh
launchctl bootout gui/$(id -u)/local.macos-alerm
```

The LaunchAgent stays registered, so it will start again at the next login.
To start it again right away:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.macos-alerm.plist
```

To also disable the automatic start at login (while keeping it installed):

```sh
launchctl bootout gui/$(id -u)/local.macos-alerm   # stop now (skip if not running)
launchctl disable gui/$(id -u)/local.macos-alerm   # don't start at login
```

To re-enable it later:

```sh
launchctl enable gui/$(id -u)/local.macos-alerm
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.macos-alerm.plist
```

(When running in the foreground instead, just press `Ctrl+C`.)

## Uninstall

```sh
./uninstall.sh
```

This stops the daemon, unregisters the LaunchAgent, and removes the plist —
it will no longer start at login. The build artifacts and your
`schedule.yaml` are left untouched.

## Writing schedule.yaml

```yaml
defaults:
  before_minutes: 1                          # how many minutes before the event to fire
  sound: /System/Library/Sounds/Glass.aiff   # alarm sound
  repeat_sound: 3                            # how many times to repeat the sound
  display: dialog                            # dialog (center of screen) | notification (Notification Center)

events:
  # Recurring event: "HH:MM". Omit weekdays to fire every day.
  - title: Standup
    message: Standup starts at 10:00
    at: "10:00"
    weekdays: [mon, tue, wed, thu, fri]      # Japanese names [月, 火, ...] also work

  # One-off event: "YYYY-MM-DD HH:MM"
  - title: Doctor appointment
    message: Leave for the clinic
    at: "2026-09-25 14:30"
    before_minutes: 10
    sound: /System/Library/Sounds/Sosumi.aiff
```

Each event can override `before_minutes`, `sound`, `repeat_sound`, and
`display` individually; omitted fields fall back to `defaults`.

Any `.aiff` under `/System/Library/Sounds/` (Glass, Sosumi, Ping, Submarine,
...) works out of the box, and you can point `sound` at any audio file path.
