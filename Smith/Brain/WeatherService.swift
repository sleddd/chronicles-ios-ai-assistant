import Foundation
import CoreLocation
import Observation
import SmithCore

/// Weather from Open-Meteo using an approximate location.
@MainActor @Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
    private(set) var report: WeatherReport?
    private(set) var lastFetch: Date?
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var locationRound = 0

    private func finishLocation(_ l: CLLocation?) {
        let waiting = waiters
        waiters = []
        locationRound += 1
        waiting.forEach { $0.resume(returning: l) }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    /// Where to get the weather for (Settings → Weather): a place, or nil for this device's location.
    var placeProvider: () -> HomePlace? = { nil }
    /// What the weather is for, for Settings ("Portland", "This device").
    private(set) var placeName: String?
    private(set) var problem: String?
    private var lastKey: String?

    func refresh(fahrenheit: Bool, force: Bool = false) async {
        let place = placeProvider()
        let key = place.map { "\($0.latitude),\($0.longitude)" } ?? "device"
        if !force, key == lastKey, let lastFetch, Date().timeIntervalSince(lastFetch) < 900, report != nil { return }
        let lat: Double, lon: Double
        if let place {
            lat = place.latitude; lon = place.longitude; placeName = place.name
        } else if let loc = await location() {
            lat = loc.coordinate.latitude; lon = loc.coordinate.longitude; placeName = "This device’s location"
        } else {
            problem = "Smith doesn’t know where you are. Choose a place in Settings → Weather, or allow Location for Smith."
            return
        }
        do {
            report = try await OpenMeteo.fetch(latitude: lat, longitude: lon, fahrenheit: fahrenheit)
            lastFetch = Date(); lastKey = key; problem = nil
        } catch {
            problem = "The weather service didn’t answer."
        }
    }

    func fetchLine() async throws -> String {
        let f = UserDefaults.standard.bool(forKey: "fahrenheit")
        await refresh(fahrenheit: f)
        guard let report else { return problem ?? "Weather isn't available right now." }
        return "\(placeName.map { "In \($0): " } ?? "")\(report.line)"
    }

    private func location() async -> CLLocation? {
        if let l = manager.location, Date().timeIntervalSince(l.timestamp) < 3600 { return l }
        switch manager.authorizationStatus {
        case .notDetermined:
            #if os(macOS)
            manager.requestWhenInUseAuthorization()
            #else
            manager.requestWhenInUseAuthorization()
            #endif
        case .denied, .restricted: return nil
        default: break
        }
        return await withCheckedContinuation { c in
            // Several can ask at once (launch, Settings, the weather tool): all are answered together
            waiters.append(c)
            guard waiters.count == 1 else { return }
            manager.requestLocation()
            // An unanswered permission prompt sends nothing back: don't wait on it for ever
            let round = locationRound
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.locationRound == round else { return }
                self.finishLocation(self.manager.location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let l = locations.last
        Task { @MainActor in self.finishLocation(l) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishLocation(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let denied = manager.authorizationStatus == .denied
        Task { @MainActor in
            if denied, !self.waiters.isEmpty { self.finishLocation(nil) }
        }
    }
}

/// When this side-loaded install stops working (iPad, 7-day Personal Team profile).
enum InstallInfo {
    static let expiration: Date? = {
        #if os(iOS)
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>") else { return nil }
        let plist = Data(text[start.lowerBound..<end.upperBound].utf8)
        let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        return dict?["ExpirationDate"] as? Date
        #else
        return nil
        #endif
    }()
}
