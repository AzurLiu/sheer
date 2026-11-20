// Sheer's tests: plain Swift, built together with Sources/ (minus Sources/main.swift) by test.sh, so they
// need no test framework (the Command Line Tools ship without XCTest). Each `check` that fails prints
// where and what; the run exits non-zero if any did. 测试：由 test.sh 与源码一起编译运行
//
// The Dynamic-wallpaper cases are moments actually seen on a Mac in Nov 2026 (time zone America/Regina,
// Location Services for setting the time zone off): keep them passing when changing that logic.

import AppKit

var failures = 0, checks = 0
func check(_ ok: @autoclosure () -> Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !ok() { failures += 1; print("✗ \(file):\(line)  \(what)") }
}
func section(_ name: String) { print("· \(name)") }

let regina = TimeZone(identifier: "America/Regina")!
func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, in zone: TimeZone = regina) -> Date {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

// MARK: - Sun position

section("sun position")
do {
    // Equinox, solar noon on the equator at Greenwich: the sun is (nearly) straight overhead.
    let noon = Solar.position(local(2026, 3, 20, 12, 7, in: TimeZone(identifier: "UTC")!), lat: 0, lon: 0)
    check(noon.alt > 88, "equinox noon on the equator: altitude \(noon.alt)")
    // Midsummer in London at solar noon: 90 − 51.5 + 23.44 ≈ 61.9°.
    let london = Solar.position(local(2026, 6, 21, 12, 2, in: TimeZone(identifier: "UTC")!), lat: 51.5, lon: -0.13)
    check(abs(london.alt - 61.9) < 0.7, "London midsummer noon: altitude \(london.alt)")
    // Morning sun in the east (azimuth < 180°), afternoon sun in the west.
    check(Solar.position(local(2026, 11, 17, 10, 0), lat: 50.45, lon: -104.6).az < 180, "Regina morning: sun in the east")
    check(Solar.position(local(2026, 11, 17, 15, 0), lat: 50.45, lon: -104.6).az > 180, "Regina afternoon: sun in the west")
}

// MARK: - Dynamic wallpaper frames

// The sun schedule of macOS's "Ventura Graphic" Dynamic wallpaper (apple_desktop:solar → si): altitude a,
// azimuth z, image i. Copied here so the tests don't need the 32 MB wallpaper file.
let ventura: [[String: Any]] = [
    ["a": 25, "z": 110, "i": 0], ["a": -25, "z": 70, "i": 1], ["a": -9, "z": 80, "i": 2], ["a": 0, "z": 90, "i": 3],
    ["a": 10, "z": 100, "i": 4], ["a": 25, "z": 250, "i": 0], ["a": 10, "z": 260, "i": 4], ["a": 0, "z": 270, "i": 3],
    ["a": -9, "z": 280, "i": 2], ["a": -25, "z": 290, "i": 1],
]
let meridian = (lat: 0.0, lon: -90.0)                   // the equator at UTC−6's meridian
let edmonton = (lat: 53.52, lon: -113.53)               // where that Mac actually was
func ventFrame(_ date: Date, _ place: (lat: Double, lon: Double)) -> Int { Solar.frame(ventura, at: date, place: place) ?? -1 }
func at(_ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date { local(2026, 11, d, h, mi).addingTimeInterval(Double(s)) }

section("Dynamic wallpaper: the desktop's own image changes")
do {
    // From the desktop's log on that Mac (time-zone location service off), Wed 18 Nov: the moment it
    // chose each image. Sheer's computation, standing on the equator at the zone's meridian, must give
    // the image before each moment and the new one after (3 minutes' margin: the log's own times are
    // within the minute of Sheer's with the system's sun, a little further with the built-in formula).
    let seen: [(Date, Int)] = [
        (at(18, 4, 29, 38), 2), (at(18, 5, 22, 45), 3), (at(18, 6, 5, 29), 4), (at(18, 6, 59, 5), 0),
        (at(18, 16, 30, 56), 4), (at(18, 17, 24, 34), 3), (at(18, 18, 7, 20), 2), (at(18, 19, 0, 30), 1),
    ]
    var before = 1   // night, until the first change
    for (moment, image) in seen {
        check(ventFrame(moment.addingTimeInterval(-180), meridian) == before, "before \(moment): image \(before)")
        check(ventFrame(moment.addingTimeInterval(180), meridian) == image, "after \(moment): image \(image)")
        before = image
    }
    // Sun 15 Nov, the service still on: the desktop stood where the Mac was, and chose 3 at 16:48:11.
    check(ventFrame(at(15, 16, 55, 0), edmonton) == 3, "15 Nov 16:55 near Edmonton → 3")
    check(ventFrame(at(15, 16, 55, 0), meridian) == 4, "…where the meridian point still gives 4")
}

section("Dynamic wallpaper: which position Sheer computes from")
do {
    // test.sh runs this with TZ=America/Regina. With the time-zone location service off (as on that Mac,
    // and on CI), the desktop stands on the equator at the zone's meridian, and so must Sheer: the
    // zone's city (used from 1.3.2 to 1.4.1) is up to an hour and a half out of step.
    if TimeZone.current.identifier == "America/Regina" && !Solar.desktopUsesRealLocation {
        let p = Solar.location
        check(abs(p.lat) < 0.01 && abs(p.lon + 90) < 0.5, "location off → the zone's meridian on the equator (got \(p))")
    } else {
        print("  (skipped: needs TZ=America/Regina and the time-zone location service off)")
    }
}

section("Dynamic wallpaper: which image a look at the desktop sees")
do {
    // Distances of the desktop's picture to each of Ventura Graphic's five images, as measured.
    check(WallpaperProvider.match([0, 64, 53, 38, 16]) == 0, "the day image")
    check(WallpaperProvider.match([38, 30, 19, 0, 23]) == 3, "the evening image")
    check(WallpaperProvider.match([63, 0, 12, 30, 49]) == 1, "the night image")
    // Halfway through a change, or something else on the desktop: no answer rather than a guess.
    check(WallpaperProvider.match([9, 60, 50, 35, 9]) == nil, "between two images")
    check(WallpaperProvider.match([40, 45, 50, 38, 42]) == nil, "none of them")
    check(WallpaperProvider.match([]) == nil, "nothing to compare")
    check(WallpaperProvider.match([3]) == 0, "a single image")
}

section("Dynamic wallpaper: reading the desktop's notes")
do {
    let us = Locale(identifier: "en_US")
    // A note as the log holds it.
    let message = """
        indexAndNextDate: {
            dynamicStyle: automatic
            appearance: light,
            queryOptions: []),
            location: <private>,
            isMainThread: true
        } -> 3, nextDate: Nov 15, 2026 at 6:08:57 PM
        """
    let note = DesktopLog.parse(message, at: at(15, 16, 48, 11), locale: us, zone: regina)
    check(note?.index == 3, "the image: \(String(describing: note?.index))")
    check(note?.next == at(15, 18, 8, 57), "the next time: \(String(describing: note?.next))")
    // The log's other lines aren't notes.
    check(DesktopLog.parse("SolarTrigger timer fired.", at: Date(), locale: us, zone: regina) == nil, "timer line")
    check(DesktopLog.parse("Updated solar trigger, scheduling next update for Nov 18, 2026 at 6:05:29 AM", at: Date(), locale: us, zone: regina) == nil, "schedule line")
    // No further change that day reads as the year 4000: the image counts, the time doesn't.
    let last = DesktopLog.parse("indexAndNextDate: {} -> 1, nextDate: Dec 31, 4000 at 6:00:00 PM", at: at(17, 19, 24, 22), locale: us, zone: regina)
    check(last?.index == 1 && last?.next == nil, "far-future next time is dropped")
    // A region that writes dates another way: read with the same region's format.
    let zh = Locale(identifier: "zh_CN")
    let f = DateFormatter(); f.locale = zh; f.timeZone = regina; f.dateStyle = .medium; f.timeStyle = .medium
    let chinese = DesktopLog.parse("indexAndNextDate: {} -> 2, nextDate: \(f.string(from: at(18, 19, 0, 30)))", at: at(18, 18, 7, 20), locale: zh, zone: regina)
    check(chinese?.index == 2 && chinese?.next == at(18, 19, 0, 30), "Chinese-format date: \(String(describing: chinese?.next))")
    // Unreadable date: still the image.
    let odd = DesktopLog.parse("indexAndNextDate: {} -> 4, nextDate: sometime", at: Date(), locale: us, zone: regina)
    check(odd?.index == 4 && odd?.next == nil, "unreadable date keeps the image")
}

section("Dynamic wallpaper: which note counts")
do {
    typealias Note = DesktopLog.Note
    let places = [meridian]
    func noted(_ notes: [Note], since: Date? = nil, mixed: Bool = false, now: Date) -> Int? {
        Solar.noted(notes, si: ventura, count: 5, since: since, mixed: mixed, places: places, now: now)
    }
    let evening = [Note(date: at(18, 16, 30, 56), index: 4, next: at(18, 17, 24, 34)),
                   Note(date: at(18, 17, 24, 34), index: 3, next: at(18, 18, 7, 20))]
    check(noted(evening, now: at(18, 17, 30, 0)) == 3, "the newest note")
    check(noted(Array(evening.prefix(1)), now: at(18, 17, 0, 0)) == 4, "one note")
    check(noted([], now: at(18, 17, 0, 0)) == nil, "no notes → compute")
    // Another wallpaper's note (more images than this one has) is not about this wallpaper.
    let foreign = evening + [Note(date: at(18, 17, 26, 0), index: 6, next: nil)]
    check(noted(foreign, now: at(18, 17, 30, 0)) == 3, "an index this wallpaper doesn't have is skipped")
    // Notes from before this wallpaper was set are about the previous one.
    check(noted(evening, since: at(18, 17, 0, 0), now: at(18, 17, 30, 0)) == 3, "since: the later note still counts")
    check(noted(evening, since: at(18, 17, 28, 0), now: at(18, 17, 30, 0)) == nil, "since: both too old")
    // Past its "next" time by a good margin with nothing newer, a note is out of date.
    check(noted(evening, now: at(18, 18, 9, 0)) == 3, "just past the next time: still shown")
    check(noted(evening, now: at(18, 18, 30, 0)) == nil, "long past the next time → compute")
    check(noted([Note(date: at(18, 6, 59, 5), index: 0, next: nil)], now: at(18, 12, 0, 0)) == 0, "no next time: good for hours")
    check(noted([Note(date: at(18, 6, 59, 5), index: 0, next: nil)], now: at(18, 21, 0, 0)) == nil, "…but not for ever")
    // The lock screen has a sun-following wallpaper of its own: only notes that fit this one's schedule.
    let other = evening + [Note(date: at(18, 17, 26, 0), index: 1, next: nil)]
    check(noted(other, mixed: true, now: at(18, 17, 30, 0)) == 3, "mixed: the note that doesn't fit is skipped")
    check(noted(other, mixed: false, now: at(18, 17, 30, 0)) == 1, "not mixed: the newest note is taken as is")
}

// MARK: - Updates

section("update versions and notes")
do {
    let newer = UpdateChecker.isNewer
    check(newer("1.3.2", "1.3.1"), "1.3.2 > 1.3.1")
    check(newer("1.10.0", "1.9.9"), "1.10.0 > 1.9.9 (numbers, not text)")
    check(newer("2.0", "1.9.9"), "2.0 > 1.9.9")
    check(!newer("1.3.2", "1.3.2"), "same version isn't newer")
    check(!newer("1.3", "1.3.0"), "1.3 == 1.3.0")
    check(!newer("1.2.9", "1.3.0"), "older isn't newer")

    let notes = "Fixes the menu bar.\r\n---\r\n修复了菜单栏。\r\n---\r\nUnzip and open."
    check(UpdateChecker.localized(notes, chinese: false) == "Fixes the menu bar.", "English part (CRLF)")
    check(UpdateChecker.localized(notes, chinese: true) == "修复了菜单栏。", "Chinese part")
    check(UpdateChecker.localized("Unzip and open.", chinese: false) == nil, "old releases: install line only → nil")
    check(UpdateChecker.localized(nil) == nil, "no notes → nil")
    let long = String(repeating: "a", count: 900) + "\n---\nb\n---\nc"
    check(UpdateChecker.localized(long, chinese: false)?.count == 600, "notes are capped at 600 characters")
}

// MARK: - Wallpaper settings (the system's wallpaper store)

section("wallpaper store")
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sheer-tests-\(getpid())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let picture = dir.appendingPathComponent("Picture.heic")
    FileManager.default.createFile(atPath: picture.path, contents: Data([0]))
    let original = WallpaperProvider.storeIndexURL
    defer { WallpaperProvider.storeIndexURL = original }

    /// Writes an Index.plist like the system's and resolves it.
    func resolve(provider: String, style: Int? = nil, file: URL? = nil, shuffle: Any = "$null",
                 displays: [String: Any] = [:], dark: Bool = false) -> WallpaperProvider.Source {
        var choice: [String: Any] = ["Provider": provider, "Files": file.map { [["relative": $0.absoluteString]] } ?? []]
        if let style {
            choice["Configuration"] = try! PropertyListSerialization.data(fromPropertyList: ["style": style], format: .binary, options: 0)
        }
        let root: [String: Any] = [
            "AllSpacesAndDisplays": ["Desktop": ["Content": ["Choices": [choice], "Shuffle": shuffle]]],
            "Displays": displays, "Spaces": [String: Any](),
        ]
        let url = dir.appendingPathComponent("Index.plist")
        try! PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
        WallpaperProvider.storeIndexURL = url
        return WallpaperProvider.resolve(dark: dark)
    }

    let dynamic = "com.apple.wallpaper.choice.dynamic"
    check(resolve(provider: dynamic, style: 0, file: picture) == .file(picture, dark: false, solar: true), "Dynamic, style 0 follows the sun")
    check(resolve(provider: dynamic, style: 1, file: picture) == .file(picture, dark: false, solar: true), "Dynamic, style 1 follows the sun")
    check(resolve(provider: dynamic, style: 2, file: picture, dark: true) == .file(picture, dark: false, solar: false), "Dynamic, style 2 = light")
    check(resolve(provider: dynamic, style: 3, file: picture) == .file(picture, dark: true, solar: false), "Dynamic, style 3 = dark")
    check(resolve(provider: "com.apple.wallpaper.choice.image", style: 2, file: picture) == .file(picture, dark: true, solar: false), "picture, style 2 = dark")
    check(resolve(provider: "com.apple.wallpaper.choice.image", file: picture, dark: true) == .file(picture, dark: true, solar: false), "picture, automatic follows the appearance")
    check(resolve(provider: "default") == .systemDefault, "the default wallpaper")
    check(resolve(provider: dynamic, file: picture, shuffle: "every hour") == .needsCapture("shuffle"), "shuffling needs a capture")
    check(resolve(provider: dynamic, file: picture, displays: ["1": ["x": 1]]) == .needsCapture("per-display wallpaper"), "per-display needs a capture")
    check(resolve(provider: "com.example.live") == .needsCapture("com.example.live"), "live wallpaper without a file needs a capture")
    if #available(macOS 14, *) {
        WallpaperProvider.storeIndexURL = dir.appendingPathComponent("missing.plist")
        check(WallpaperProvider.resolve(dark: false) == .systemDefault, "no store → the default picture")
    }
}

// MARK: - Legibility gradient

section("legibility gradient")
do {
    check(Scrim.alpha(lum: 0.8, darkText: true) == 0, "dark text on a bright wallpaper needs nothing")
    check(Scrim.alpha(lum: 0.02, darkText: false) == 0, "light text on a dark wallpaper needs nothing")
    check(Scrim.alpha(lum: 0.5, darkText: false) == 0.3, "light text on a mid wallpaper: capped at 0.3")
    let a = Scrim.alpha(lum: 0.25, darkText: false)
    check(a > 0 && a < 0.3, "light text on a light-ish wallpaper: some backing (\(a))")
    check(Scrim.falloff(0) == 1 && Scrim.falloff(1) == 0, "gradient runs from full to nothing")
}

print(failures == 0 ? "✅ \(checks) checks passed" : "❌ \(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
