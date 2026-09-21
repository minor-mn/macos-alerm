// macOS 常駐アラームデーモン
//
// schedule.yaml を10分毎(またはファイル更新時)に再読み込みし、
// 各予定の「発火時刻(予定時刻 - before_minutes)」になったら
// 指定のアラーム音を鳴らし、指定のメッセージを画面表示する。
//
// launchd (LaunchAgent) から起動されることを想定。単体実行も可:
//     .build/release/macos-alerm /path/to/schedule.yaml

import Foundation
import Yams

// MARK: - 定数

let reloadIntervalSec: TimeInterval = 600      // スケジュール再読み込み間隔(10分)
let tickSec: TimeInterval = 15                 // 時刻チェック間隔
let graceSec: TimeInterval = 120               // 発火時刻からこの秒数以内なら鳴らす(スリープ復帰対策)
let stateKeepSec: TimeInterval = 2 * 86400     // 発火済み記録の保持期間

let defaultBeforeMinutes = 1
let defaultSound = "/System/Library/Sounds/Glass.aiff"
let defaultRepeatSound = 3
let defaultDisplay = "dialog"                  // dialog | notification

let stateDir = NSString(string: "~/.local/state/macos-alerm").expandingTildeInPath
let statePath = stateDir + "/fired.json"

// MARK: - ログ

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func log(_ msg: String) {
    print("\(logFormatter.string(from: Date())) \(msg)")
    fflush(stdout)
}

// MARK: - スケジュール定義

enum When {
    case oneoff(Date)
    // weekday は Calendar 準拠 (1=日 ... 7=土)。nil なら毎日。
    case recurring(hour: Int, minute: Int, weekdays: Set<Int>?)
}

struct AlarmEvent {
    let title: String
    let message: String
    let when: When
    let beforeMinutes: Int
    let sound: String
    let repeatSound: Int
    let display: String
}

struct ScheduleFile: Decodable {
    struct Defaults: Decodable {
        var before_minutes: Int?
        var sound: String?
        var repeat_sound: Int?
        var display: String?
    }
    struct RawEvent: Decodable {
        var title: String
        var message: String?
        var at: String
        var weekdays: [String]?
        var before_minutes: Int?
        var sound: String?
        var repeat_sound: Int?
        var display: String?
    }
    var defaults: Defaults?
    var events: [RawEvent]?
}

let weekdayNames: [String: Int] = [
    "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
    "日": 1, "月": 2, "火": 3, "水": 4, "木": 5, "金": 6, "土": 7,
]

func makeFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.dateFormat = format
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    return f
}

let oneoffFormatters = ["yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm"].map(makeFormatter)
let hhmmFormatter = makeFormatter("HH:mm")

/// "HH:MM"(繰り返し) または "YYYY-MM-DD HH:MM"(単発) を解釈する。
func parseAt(_ value: String, weekdays: Set<Int>?) -> When? {
    let s = value.trimmingCharacters(in: .whitespaces)
    for fmt in oneoffFormatters {
        if let date = fmt.date(from: s) {
            return .oneoff(date)
        }
    }
    let parts = s.split(separator: ":")
    if parts.count == 2,
       let h = Int(parts[0]), let m = Int(parts[1]),
       (0...23).contains(h), (0...59).contains(m) {
        return .recurring(hour: h, minute: m, weekdays: weekdays)
    }
    return nil
}

func loadSchedule(path: String) throws -> [AlarmEvent] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let file = try YAMLDecoder().decode(ScheduleFile.self, from: text)

    let beforeMinutes = file.defaults?.before_minutes ?? defaultBeforeMinutes
    let sound = file.defaults?.sound ?? defaultSound
    let repeatSound = file.defaults?.repeat_sound ?? defaultRepeatSound
    let display = file.defaults?.display ?? defaultDisplay

    var events: [AlarmEvent] = []
    for (i, raw) in (file.events ?? []).enumerated() {
        var weekdays: Set<Int>? = nil
        if let names = raw.weekdays {
            var set = Set<Int>()
            for name in names {
                guard let wd = weekdayNames[name.lowercased()] else {
                    log("WARN: events[\(i)] '\(raw.title)': 不明な曜日 '\(name)'")
                    continue
                }
                set.insert(wd)
            }
            weekdays = set
        }
        guard let when = parseAt(raw.at, weekdays: weekdays) else {
            log("WARN: events[\(i)] '\(raw.title)' をスキップ: at '\(raw.at)' を解釈できません")
            continue
        }
        events.append(AlarmEvent(
            title: raw.title,
            message: raw.message ?? raw.title,
            when: when,
            beforeMinutes: raw.before_minutes ?? beforeMinutes,
            sound: raw.sound ?? sound,
            repeatSound: raw.repeat_sound ?? repeatSound,
            display: raw.display ?? display
        ))
    }
    return events
}

// MARK: - 発火判定

/// 指定した日(複数)における予定時刻を列挙する。
func occurrences(of ev: AlarmEvent, onDays days: [Date], calendar: Calendar) -> [Date] {
    var result: [Date] = []
    for day in days {
        switch ev.when {
        case .oneoff(let date):
            if calendar.isDate(date, inSameDayAs: day) {
                result.append(date)
            }
        case .recurring(let hour, let minute, let weekdays):
            if let wds = weekdays, !wds.contains(calendar.component(.weekday, from: day)) {
                continue
            }
            if let occ = calendar.date(bySettingHour: hour, minute: minute, second: 0,
                                       of: calendar.startOfDay(for: day)) {
                result.append(occ)
            }
        }
    }
    return result
}

// MARK: - アラーム実行

func osaEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}

func runDetached(_ executable: String, _ arguments: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    do {
        try p.run()
    } catch {
        log("ERROR: \(executable) の起動に失敗: \(error)")
    }
}

/// アラーム音を鳴らし、メッセージを画面表示する(どちらも非同期)。
func fire(_ ev: AlarmEvent, occurrence occ: Date) {
    log("ALARM: \(ev.title) (予定 \(logFormatter.string(from: occ)))")

    if FileManager.default.fileExists(atPath: ev.sound) {
        let quoted = ev.sound.replacingOccurrences(of: "\"", with: "\\\"")
        let cmd = "for i in $(seq \(max(1, ev.repeatSound))); do afplay \"\(quoted)\"; done"
        runDetached("/bin/sh", ["-c", cmd])
    } else {
        log("WARN: 音声ファイルが見つかりません: \(ev.sound)")
    }

    let title = osaEscape(ev.title)
    let script: String
    if ev.display == "notification" {
        script = "display notification \"\(osaEscape(ev.message))\" with title \"\(title)\""
    } else {
        let body = osaEscape("\(ev.message)\n\n予定時刻: \(hhmmFormatter.string(from: occ))")
        script = "display dialog \"\(body)\" with title \"\(title)\" "
            + "buttons {\"OK\"} default button \"OK\" with icon caution giving up after 3600"
    }
    runDetached("/usr/bin/osascript", ["-e", script])
}

// MARK: - 発火済み状態の永続化(再起動時の二重発火防止)

func loadState() -> [String: Double] {
    guard let data = FileManager.default.contents(atPath: statePath),
          let state = try? JSONDecoder().decode([String: Double].self, from: data) else {
        return [:]
    }
    return state
}

func saveState(_ state: [String: Double]) {
    do {
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    } catch {
        log("WARN: 状態ファイルの保存に失敗: \(error)")
    }
}

// MARK: - メインループ

func schedulePath() -> String {
    if CommandLine.arguments.count > 1 {
        return CommandLine.arguments[1]
    }
    if let env = ProcessInfo.processInfo.environment["ALARM_SCHEDULE"] {
        return env
    }
    return FileManager.default.currentDirectoryPath + "/schedule.yaml"
}

func main() -> Never {
    let path = schedulePath()
    let calendar = Calendar.current
    let isoFormatter = ISO8601DateFormatter()
    log("起動: schedule=\(path)")

    var fired = loadState()
    var events: [AlarmEvent] = []
    var lastLoad: TimeInterval = 0
    var lastMtime: Date? = nil

    while true {
        let nowTs = Date().timeIntervalSince1970

        // 10分毎、またはYAMLが更新されたら再読み込み
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if nowTs - lastLoad >= reloadIntervalSec || mtime != lastMtime {
            do {
                events = try loadSchedule(path: path)
                log("スケジュール読み込み: \(events.count)件")
            } catch {
                log("ERROR: スケジュール読み込み失敗、前回の内容を継続使用: \(error)")
            }
            lastLoad = nowTs
            lastMtime = mtime
        }

        let now = Date()
        let today = calendar.startOfDay(for: now)
        // before_minutes で日付をまたぐケースに備え、今日と明日の予定を見る
        let days = [today, calendar.date(byAdding: .day, value: 1, to: today)!]

        for ev in events {
            for occ in occurrences(of: ev, onDays: days, calendar: calendar) {
                let fireAt = occ.addingTimeInterval(-Double(ev.beforeMinutes) * 60)
                let key = "\(ev.title)|\(isoFormatter.string(from: occ))"
                if fired[key] != nil { continue }
                if fireAt <= now && now < fireAt.addingTimeInterval(graceSec) {
                    fire(ev, occurrence: occ)
                    fired[key] = nowTs
                    fired = fired.filter { nowTs - $0.value < stateKeepSec }
                    saveState(fired)
                }
            }
        }

        Thread.sleep(forTimeInterval: tickSec)
    }
}

main()
