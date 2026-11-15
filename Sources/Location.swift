// The Mac's position, for Dynamic wallpapers only: when the desktop places the sun by Location
// Services, Sheer has to stand in the same spot to change image at the same moment. Coarse (3 km,
// as the desktop asks for), refreshed a few times a day, kept on this Mac and never sent anywhere.

import CoreLocation

final class Location: NSObject, CLLocationManagerDelegate {
    static let shared = Location()
    /// Called on the main thread when the position or the permission changes.
    var onChange: (() -> Void)?

    private let manager = CLLocationManager()
    private var timer: Timer?
    private let lock = NSLock()
    private var stored: (lat: Double, lon: Double)?

    private override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "locationLatitude") != nil {
            stored = (d.double(forKey: "locationLatitude"), d.double(forKey: "locationLongitude"))
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    /// Last known position while Sheer is allowed to know it. Safe from any thread.
    var coordinate: (lat: Double, lon: Double)? {
        lock.lock(); defer { lock.unlock() }
        return allowed ? stored : nil
    }
    private var allowed = false

    /// The last position Sheer was ever given, kept even after Location Services is switched off.
    /// A desktop whose time-zone service was switched off keeps the position it had then, so this is
    /// the best stand-in for it. Safe from any thread.
    var lastKnown: (lat: Double, lon: Double)? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var isAuthorized: Bool { Self.authorized(manager.authorizationStatus) }
    /// The user hasn't been asked yet (asking again after a refusal does nothing).
    var isUndetermined: Bool { manager.authorizationStatus == .notDetermined }

    private static func authorized(_ s: CLAuthorizationStatus) -> Bool { s.rawValue == 3 || s.rawValue == 4 }

    /// Start following the position if that's already allowed. Doesn't prompt.
    func start() {
        setAllowed(isAuthorized)
        guard isAuthorized else { return }
        manager.requestLocation()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.manager.requestLocation() }
        timer?.tolerance = 600
    }

    /// Show the system's permission prompt.
    func request() { manager.requestWhenInUseAuthorization() }

    private func setAllowed(_ value: Bool) {
        lock.lock(); allowed = value; lock.unlock()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isAuthorized { start() } else { setAllowed(false); timer?.invalidate() }
        onChange?()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        lock.lock()
        let moved = stored.map { abs($0.lat - c.latitude) > 0.01 || abs($0.lon - c.longitude) > 0.01 } ?? true
        stored = (c.latitude, c.longitude)
        lock.unlock()
        UserDefaults.standard.set(c.latitude, forKey: "locationLatitude")
        UserDefaults.standard.set(c.longitude, forKey: "locationLongitude")
        if moved { onChange?() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}   // keep the last position
}
