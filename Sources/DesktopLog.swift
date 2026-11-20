// What the desktop itself says a Dynamic (sun-following) wallpaper shows.
//
// Each time macOS's wallpaper extension picks an image, it notes the choice in the system log
// (subsystem com.apple.wallpaper, category solar-trigger; seen on macOS 15):
//
//     indexAndNextDate: { … } -> 3, nextDate: Nov 15, 2026 at 6:08:57 PM
//
// the image's index, and when it will choose again. Sheer reads those notes, so it knows of a change
// the second it happens, without capturing the screen to find out. (It used to, which macOS shows as
// screen recording, hundreds of times a day.) The desktop doesn't always show its choice at once,
// though: Sheer still looks at the desktop's picture to see what is there (WallpaperProvider.look).
//
// The notes are read when the desktop said it would choose again, at the events that make it choose
// (waking, a clock or appearance change, a new wallpaper), and every half hour to be safe. Reading
// takes an administrator account; where the log can't be read, or holds no notes (older macOS),
// `notes` stays empty and Sheer computes the image itself (see Solar).

import Foundation
import OSLog

final class DesktopLog {
    static let shared = DesktopLog()

    struct Note: Equatable {
        /// When the desktop chose.
        let date: Date
        /// The image it chose.
        let index: Int
        /// When it will choose again, where that could be read.
        let next: Date?
    }

    /// On the main thread, after a read that found notes not seen before.
    var onChange: (() -> Void)?

    /// Whether a sun-following wallpaper is on the desktop: the notes are only read while one is.
    /// Main thread.
    var wanted = false {
        didSet {
            guard wanted != oldValue else { return }
            if wanted { read() } else { timer?.invalidate(); timer = nil }
        }
    }

    /// The first read is done: until then there's no telling whether the desktop keeps notes. Main thread.
    private(set) var settled = false

    /// The desktop's notes, oldest first. Safe from any thread.
    var notes: [Note] { lock.lock(); defer { lock.unlock() }; return _notes }

    private let lock = NSLock()
    private var _notes: [Note] = []
    private let queue = DispatchQueue(label: "sheer.desktop-log", qos: .utility)
    private var readTo: Date?              // notes up to here are in (touched on `queue`)
    private var reading = false, again = false
    private var timer: Timer?
    private var misses = 0

    private static let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", "com.apple.wallpaper", "solar-trigger")
    private static let process = "WallpaperDynamicExtension"
    /// How far back the first read looks, widening until it finds a note: the desktop chooses at
    /// least every twelve hours (noon and midnight), usually every few.
    private static let firstLooks: [TimeInterval] = [3600, 6 * 3600, 14 * 3600]
    private static let safetyInterval: TimeInterval = 30 * 60
    /// Without a readable "next" time, look more often (Sheer also reads when its own computation changes).
    private static let blindInterval: TimeInterval = 5 * 60
    private static let kept = 40

    /// Read the notes written since the last read, then plan the next read. Main thread.
    func read() {
        guard wanted else { return }
        if reading { again = true; return }
        reading = true
        queue.async { [self] in
            let found = scan()
            DispatchQueue.main.async { [self] in
                reading = false
                finish(found)
            }
        }
    }

    /// Read now and once more shortly: for events the desktop answers with a note of its own a moment later.
    func readSoon() {
        read()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.read() }
    }

    /// nil: the log can't be read.
    private func scan() -> [Note]? {
        let now = Date()
        #if SHEER_DEBUG
        // `defaults write io.github.sheer.Sheer noDesktopLog -bool true`: as on an account that can't read the log.
        if UserDefaults.standard.bool(forKey: "noDesktopLog") { return nil }
        #endif
        do {
            let store = try OSLogStore.local()
            // Since the last read; the first time, or after a long gap, the last hours.
            let recent = readTo.flatMap { now.timeIntervalSince($0) < Self.firstLooks[0] ? $0.addingTimeInterval(-2) : nil }
            let starts = recent.map { [$0] } ?? Self.firstLooks.map { now.addingTimeInterval(-$0) }
            var found: [Note] = []
            for start in starts {
                found = []
                for entry in try store.getEntries(at: store.position(date: start), matching: Self.predicate) {
                    // Other wallpapers' extensions write the same kind of note (the lock screen's, say):
                    // the desktop's sun-following pictures are the Dynamic extension's.
                    guard entry.date >= start, (entry as? OSLogEntryFromProcess)?.process == Self.process,
                          let note = Self.parse(entry.composedMessage, at: entry.date) else { continue }
                    found.append(note)
                }
                if !found.isEmpty { break }
            }
            readTo = now
            return found
        } catch {
            Debug.write("\(Date()) desktop log unreadable: \(error)\n", "desktop-log.txt")
            return nil
        }
    }

    private func finish(_ found: [Note]?) {
        var fresh = false
        lock.lock()
        for note in found ?? [] where !_notes.contains(where: { $0.index == note.index && abs($0.date.timeIntervalSince(note.date)) < 0.001 }) {
            _notes.append(note); fresh = true
        }
        _notes.sort { $0.date < $1.date }
        if _notes.count > Self.kept { _notes.removeFirst(_notes.count - Self.kept) }
        let last = _notes.last
        lock.unlock()
        let first = !settled
        settled = true
        if fresh {
            Debug.write("\(Date()) desktop notes: image \(last?.index ?? -1) since \(last?.date as Any), next \(last?.next as Any)\n", "desktop-log.txt")
            misses = 0
        }
        if fresh || first { onChange?() }
        if again { again = false; read(); return }
        plan(readable: found != nil, last: last, fresh: fresh)
    }

    private func plan(readable: Bool, last: Note?, fresh: Bool) {
        timer?.invalidate(); timer = nil
        guard wanted else { return }
        var delay = readable && last?.next == nil ? Self.blindInterval : Self.safetyInterval
        if let next = last?.next {
            let until = next.timeIntervalSinceNow
            if until > 0 {
                delay = min(delay, until + 0.6)   // its note is written within the second
            } else if until > -600 && !fresh {
                // The desktop's time to choose has come and its note isn't there yet: look again shortly.
                misses += 1
                delay = min(delay, misses <= 3 ? 2 : misses <= 8 ? 15 : 60)
            }
        }
        Debug.write("\(Date()) next read in \(Int(delay)) s (readable: \(readable))\n", "desktop-plan.txt")
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.read() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The image and the next time from one of the desktop's notes; nil for the log's other lines.
    static func parse(_ message: String, at date: Date, locale: Locale = .current, zone: TimeZone = .current) -> Note? {
        guard message.hasPrefix("indexAndNextDate"), let arrow = message.range(of: "-> ", options: .backwards) else { return nil }
        let tail = message[arrow.upperBound...]
        guard let index = Int(tail.prefix { ("0"..."9").contains($0) }) else { return nil }
        var next: Date?
        if let label = tail.range(of: "nextDate: ") {
            let text = tail[label.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            // A time with no chosen image left that day reads as the far future ("Dec 31, 4000"): no use.
            next = formatters(locale, zone).lazy.compactMap { $0.date(from: text) }
                .first { $0 > date && $0.timeIntervalSince(date) < 26 * 3600 }
        }
        return Note(date: date, index: index, next: next)
    }

    /// The note's time is written the way the user's region writes dates (medium date and time), in
    /// the Mac's time zone; US English is tried too.
    private static func formatters(_ locale: Locale, _ zone: TimeZone) -> [DateFormatter] {
        var all: [DateFormatter] = []
        for id in [locale.identifier, "en_US"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: id); f.timeZone = zone
            f.dateStyle = .medium; f.timeStyle = .medium
            f.isLenient = true
            all.append(f)
        }
        let fixed = DateFormatter()
        fixed.locale = Locale(identifier: "en_US_POSIX"); fixed.timeZone = zone
        fixed.dateFormat = "MMM d, yyyy 'at' h:mm:ss a"
        fixed.isLenient = true
        all.append(fixed)
        return all
    }
}
