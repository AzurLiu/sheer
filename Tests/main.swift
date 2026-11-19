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
let reginaCity = (lat: 50.40, lon: -104.65)            // zone.tab's America/Regina
let edmonton = (lat: 53.52, lon: -113.53)               // where that Mac actually was
let meridian = (lat: 0.0, lon: -90.0)                   // the equator at UTC−6's meridian
func ventFrame(_ date: Date, _ place: (lat: Double, lon: Double)) -> Int { Solar.frame(ventura, at: date, place: place) ?? -1 }

section("Dynamic wallpaper: frames seen on the desktop")
do {
    // Sun 15 Nov, 16:50: the desktop showed image 3 (its own capture, 16:57: distances [38, 30, 19, 0, 22]).
    check(ventFrame(local(2026, 11, 15, 16, 50), reginaCity) == 3, "15 Nov 16:50 → 3")
    // Sun 15 Nov, just after 18:00: the desktop showed image 2.
    check(ventFrame(local(2026, 11, 15, 18, 6), reginaCity) == 2, "15 Nov 18:06 → 2")
    // Tue 17 Nov: image 1 by 19:00 (Regina's own change is computed for ~19:03, a few minutes late).
    check(ventFrame(local(2026, 11, 17, 19, 10), reginaCity) == 1, "17 Nov 19:10 → 1")
    // Midday and midnight.
    check(ventFrame(local(2026, 11, 17, 12, 0), reginaCity) == 0, "noon → 0 (day)")
    check(ventFrame(local(2026, 11, 17, 0, 30), reginaCity) == 1, "midnight → 1 (night)")
    // Where the Mac really was would have been half an hour late: the reason for using the zone's city.
    check(ventFrame(local(2026, 11, 17, 19, 10), edmonton) == 2, "Edmonton is still on 2 at 19:10")
}

section("Dynamic wallpaper: which position Sheer times frames by")
do {
    // test.sh runs this with TZ=America/Regina. With the time-zone location service off (as on that Mac,
    // and on CI), Sheer must stand at the zone's city: the equator or the Mac's last known position put it
    // up to half an hour out of step with the desktop.
    if TimeZone.current.identifier == "America/Regina" && !Solar.desktopUsesRealLocation {
        let p = Solar.location
        check(abs(p.lat - reginaCity.lat) < 0.01 && abs(p.lon - reginaCity.lon) < 0.01, "location off → the time zone's city (got \(p))")
    } else {
        print("  (skipped: needs TZ=America/Regina and the time-zone location service off)")
    }
}

section("Dynamic wallpaper: when to look at the desktop every few seconds")
do {
    let near = { (d: Date, places: [(lat: Double, lon: Double)]) in
        WallpaperProvider.changeIsNear(at: d, places: places) { date, place in ventFrame(date, place) }
    }
    // Tue 17 Nov 18:59, the desktop changing to image 1 any moment (seen by 19:00): watched.
    check(near(local(2026, 11, 17, 18, 59), [reginaCity]), "18:59 near Regina's 19:03 change")
    // 18:50: Regina's changes (17:41, 19:03) are both over 5 minutes away.
    check(!near(local(2026, 11, 17, 18, 50), [reginaCity]), "18:50 not near")
    check(!near(local(2026, 11, 17, 18, 30), [reginaCity]), "18:30 not near")
    // Midday, over an hour from every change (Regina 11:09/14:17): no fast watching.
    check(!near(local(2026, 11, 17, 12, 30), [reginaCity]), "12:30 not near")
    // Each close look is a screen capture: the fast-watched part of a day stays short (8 changes ≈ 80 min).
    var watched = 0
    for m in 0..<1440 where near(local(2026, 11, 18, 0, 0).addingTimeInterval(Double(m) * 60), [reginaCity]) { watched += 1 }
    check(watched <= 100, "minutes a day watched closely: \(watched)")
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
