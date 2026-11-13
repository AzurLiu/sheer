// Update check: once a day, ask GitHub for the latest release's version number. If it's newer,
// the Sheer menu shows "Update Available" linking to the download page. Nothing is downloaded or
// installed automatically, and nothing about the Mac is sent.

import Foundation

final class UpdateChecker {
    static let releasesPage = URL(string: "https://github.com/AzurLiu/sheer/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/AzurLiu/sheer/releases/latest")!
    private static let interval: TimeInterval = 24 * 3600

    /// Newer version available (e.g. "1.0.3"), or nil.
    private(set) var available: String?
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        apply(defaults.string(forKey: "latestVersion"))   // last known result, so the menu is right immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer?.tolerance = 600
    }

    private func checkIfDue() {
        let last = defaults.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last >= Self.interval else { return }
        var req = URLRequest(url: Self.api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Sheer", forHTTPHeaderField: "User-Agent")
        URLSession(configuration: .ephemeral).dataTask(with: req) { [weak self] data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }   // offline etc.: try again next hour
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async {
                guard let self else { return }
                self.defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                self.defaults.set(version, forKey: "latestVersion")
                Debug.write("\(Date()) latest=\(version) current=\(self.current)\n", "update.txt")
                self.apply(version)
            }
        }.resume()
    }

    private func apply(_ latest: String?) {
        let newer = latest.flatMap { Self.isNewer($0, than: current) ? $0 : nil }
        if newer != available { available = newer; onChange?() }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
