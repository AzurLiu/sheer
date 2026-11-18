// Update check: every hour, ask GitHub for the latest release's version number and notes. If it's
// newer, Sheer says so once (what changed, with an Update button) and its menu keeps an "Update
// Available" item. Nothing is downloaded or installed unless the user chooses to, and nothing about
// the Mac is sent.
//
// Updating: Sheer downloads the release's Sheer.zip, checks that what's inside is Sheer at that version
// and signed with the same certificate as the running copy (its designated requirement), swaps it in
// and relaunches. Signed with the same certificate, the new version keeps Sheer's permissions; and,
// downloaded by Sheer itself rather than a browser, it isn't quarantined, so macOS doesn't ask to
// confirm opening it. Where Sheer can't do that — a build not signed with the certificate, or a folder
// it can't write to — the Update button opens the download page instead.

import Foundation
import Security

final class UpdateChecker {
    static let releasesPage = URL(string: "https://github.com/AzurLiu/sheer/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/AzurLiu/sheer/releases/latest")!
    private static let interval: TimeInterval = 3600

    /// Newer version available (e.g. "1.0.3"), or nil.
    private(set) var available: String?
    /// Downloading and swapping in the newer version.
    private(set) var installing = false
    /// What the newer version changes, in the user's language when the release has it.
    var notes: String? { Self.localized(defaults.string(forKey: "latestNotes")) }
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        apply(defaults.string(forKey: "latestVersion"))   // last known result, so the menu is right immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        // Checked every quarter hour so a check is never put off much past the hour (or past waking).
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer?.tolerance = 120
    }

    private func checkIfDue() {
        let last = defaults.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last >= Self.interval else { return }
        checkNow()
    }

    #if SHEER_DEBUG
    /// `defaults write io.github.sheer.Sheer updateAPI <url>` points the check at a test release (file: URLs work).
    private var api: URL { defaults.string(forKey: "updateAPI").flatMap(URL.init(string:)) ?? Self.api }
    #else
    private var api: URL { Self.api }
    #endif

    /// Ask GitHub now. `done` (on the main thread, after `available` is updated) says whether the check
    /// got an answer; the menu's "Check for Updates…" uses it to report the result.
    func checkNow(done: ((Bool) -> Void)? = nil) {
        var req = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Sheer", forHTTPHeaderField: "User-Agent")
        URLSession(configuration: .ephemeral).dataTask(with: req) { [weak self] data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200 || Self.isTestFile(response), let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {   // offline etc.: try again next hour
                DispatchQueue.main.async { done?(false) }
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async {
                guard let self else { return }
                self.defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                self.defaults.set(version, forKey: "latestVersion")
                self.defaults.set(json["body"] as? String, forKey: "latestNotes")
                let asset = (json["assets"] as? [[String: Any]])?.first { ($0["name"] as? String) == "Sheer.zip" }
                self.defaults.set(asset?["browser_download_url"] as? String, forKey: "latestAsset")
                Debug.write("\(Date()) latest=\(version) current=\(self.current)\n", "update.txt")
                self.apply(version)
                done?(true)
            }
        }.resume()
    }

    /// The running version, for "you're up to date".
    var currentVersion: String { current }

    // MARK: Updating in place

    private var assetURL: URL? { defaults.string(forKey: "latestAsset").flatMap(URL.init(string:)) }

    /// The running copy's designated requirement: what a genuine update must satisfy.
    private static let ownRequirement: (requirement: SecRequirement, text: String)? = {
        var code: SecCode?, staticCode: SecStaticCode?, req: SecRequirement?, text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess, let req,
              SecRequirementCopyString(req, [], &text) == errSecSuccess else { return nil }
        return (req, text as String? ?? "")
    }()

    /// Sheer can update itself: it's signed with its certificate (an ad-hoc signature names only its own
    /// build, so no other version could satisfy it) and may write where it is.
    var canInstall: Bool {
        guard assetURL != nil, Self.ownRequirement?.text.contains("certificate leaf") == true else { return false }
        let app = Bundle.main.bundleURL, fm = FileManager.default
        return fm.isWritableFile(atPath: app.path) && fm.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    enum InstallError: Error { case download, check, replace }

    /// Download the newer version and swap it in for the running copy. On success, `done` gets the
    /// installed app (the caller relaunches it); on failure, why.
    func install(done: @escaping (Result<URL, InstallError>) -> Void) {
        guard !installing, let url = assetURL, let version = available else { return }
        installing = true; onChange?()
        let finish: (Result<URL, InstallError>) -> Void = { r in
            DispatchQueue.main.async {
                if case .failure = r { self.installing = false; self.onChange?() }
                done(r)
            }
        }
        URLSession(configuration: .ephemeral).downloadTask(with: url) { file, response, error in
            let fm = FileManager.default
            guard let file, error == nil, (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true else {
                return finish(.failure(.download))
            }
            let dir = fm.temporaryDirectory.appendingPathComponent("Sheer-update-\(UUID().uuidString)")
            let zip = dir.appendingPathComponent("Sheer.zip"), app = dir.appendingPathComponent("Sheer.app")
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.moveItem(at: file, to: zip)
            } catch { return finish(.failure(.download)) }
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, dir.path]
            do { try unzip.run(); unzip.waitUntilExit() } catch { return finish(.failure(.download)) }
            guard unzip.terminationStatus == 0, Self.isGenuine(app, version: version) else {
                try? fm.removeItem(at: dir)
                return finish(.failure(.check))
            }
            DispatchQueue.main.async {
                do {
                    let installed = try fm.replaceItemAt(Bundle.main.bundleURL, withItemAt: app) ?? Bundle.main.bundleURL
                    try? fm.removeItem(at: dir)
                    Debug.write("\(Date()) installed \(version) at \(installed.path)\n", "update-install.txt")
                    done(.success(installed))
                } catch {
                    try? fm.removeItem(at: dir)
                    finish(.failure(.replace))
                }
            }
        }.resume()
    }

    /// Sheer, at the announced version, signed so that it satisfies the running copy's requirement.
    private static func isGenuine(_ app: URL, version: String) -> Bool {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              let own = ownRequirement?.requirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(code, flags, own, nil) == errSecSuccess
    }

    /// A test release read from a file (debug builds only).
    private static func isTestFile(_ response: URLResponse?) -> Bool {
        #if SHEER_DEBUG
        return response?.url?.isFileURL == true
        #else
        return false
        #endif
    }

    private func apply(_ latest: String?) {
        let newer = latest.flatMap { Self.isNewer($0, than: current) ? $0 : nil }
        if newer != available { available = newer; onChange?() }
    }

    /// Release notes are written as "English\n---\n中文\n---\ninstall instructions": pick the reader's part.
    static func localized(_ body: String?) -> String? {
        guard let body else { return nil }
        let parts = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n---\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 3 else { return nil }   // older releases only carry the install instructions
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let text = String(parts[chinese ? 1 : 0].prefix(600))
        return text.isEmpty ? nil : text
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
