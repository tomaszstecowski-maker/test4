import Foundation
import Photos
import SwiftUI
import UIKit

/// Stałe informacje o telefonie (odczytane raz, na głównym wątku).
struct DeviceInfo {
    let model: String
    let vendorID: String
    let appVersion: String

    static func current() -> DeviceInfo {
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return DeviceInfo(model: machine,
                          vendorID: UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
                          appVersion: version)
    }
}

/// Jak telefon przyjmuje pliki.
enum ReceiveMode: String, CaseIterable {
    case cable, wifi, both
    var allowsCable: Bool { self != .wifi }
    var allowsWifi: Bool { self != .cable }
}

/// Ustawienia czytane z wątków sieciowych (bezpiecznie, pod blokadą).
final class SharedSettings {
    private let lock = NSLock()
    private var _name = ""
    private var _mode = ReceiveMode.both
    private var _ask = true

    var name: String {
        get { lock.lock(); defer { lock.unlock() }; return _name }
        set { lock.lock(); _name = newValue; lock.unlock() }
    }
    var mode: ReceiveMode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }
    var ask: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _ask }
        set { lock.lock(); _ask = newValue; lock.unlock() }
    }
}

/// Prośba o odbiór (jak w LocalSend – można przyjąć albo odrzucić).
struct Offer {
    let session: String
    let from: String
    let files: Int
    let bytes: Int64
    let viaUSB: Bool
    let answer: (Bool) -> Void
}

/// Losowa nazwa: przymiotnik + zwierzę, np. „Rudy Lis”.
enum NameGenerator {
    private static let adjPL = ["Rudy", "Szary", "Bystry", "Dziki", "Czujny", "Zwinny", "Leśny", "Górski", "Nocny",
                                "Śnieżny", "Złoty", "Cichy", "Sprytny", "Dzielny", "Wierny", "Polarny", "Stepowy",
                                "Nadmorski"]
    private static let nounPL = ["Lis", "Wilk", "Sokół", "Orzeł", "Jeleń", "Borsuk", "Bóbr", "Żubr", "Ryś", "Puchacz",
                                 "Delfin", "Pingwin", "Jeż", "Kruk", "Łoś", "Tygrys", "Lew", "Niedźwiedź", "Gepard",
                                 "Bażant"]
    private static let adjEN = ["Red", "Grey", "Swift", "Wild", "Alert", "Nimble", "Forest", "Mountain", "Night",
                                "Snowy", "Golden", "Silent", "Clever", "Brave", "Loyal", "Polar", "Prairie", "Coastal"]
    private static let nounEN = ["Fox", "Wolf", "Falcon", "Eagle", "Deer", "Badger", "Beaver", "Bison", "Lynx", "Owl",
                                 "Dolphin", "Penguin", "Hedgehog", "Raven", "Moose", "Tiger", "Lion", "Bear", "Cheetah",
                                 "Otter"]

    static func random() -> String {
        let pl = (Locale.preferredLanguages.first ?? "en").hasPrefix("pl")
        let a = (pl ? adjPL : adjEN).randomElement() ?? "Rudy"
        let n = (pl ? nounPL : nounEN).randomElement() ?? "Lis"
        return "\(a) \(n)"
    }
}

final class AppModel: ObservableObject {
    enum Phase { case starting, waiting, receiving, finished, error }

    @Published var phase: Phase = .starting
    @Published var listenerError: String = ""
    @Published var viaUSB = true
    @Published var peerName = ""
    @Published var connections = 0
    @Published var received = 0
    @Published var saved = 0
    @Published var failed = 0
    @Published var bytes: Int64 = 0
    @Published var speed: Double = 0          // bajty na sekundę
    @Published var currentFile = ""
    @Published var lastError = ""
    @Published var photoStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var wifiAddress: String?
    @Published var pendingOffer: Offer?

    @Published var deviceName: String {
        didSet {
            UserDefaults.standard.set(deviceName, forKey: "deviceName")
            shared.name = deviceName
            receiver?.settingsChanged()
        }
    }
    @Published var mode: ReceiveMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            shared.mode = mode
            receiver?.settingsChanged()
        }
    }
    @Published var askBeforeReceive: Bool {
        didSet {
            UserDefaults.standard.set(askBeforeReceive, forKey: "ask")
            shared.ask = askBeforeReceive
            receiver?.settingsChanged()
        }
    }

    let device: DeviceInfo
    let shared = SharedSettings()
    private var receiver: Receiver?
    private var saver: PhotoSaver?

    init() {
        device = DeviceInfo.current()
        let defaults = UserDefaults.standard
        var name = defaults.string(forKey: "deviceName") ?? ""
        if name.isEmpty {
            name = NameGenerator.random()
            defaults.set(name, forKey: "deviceName")
        }
        deviceName = name
        mode = ReceiveMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .both
        askBeforeReceive = defaults.object(forKey: "ask") as? Bool ?? true
        shared.name = deviceName
        shared.mode = mode
        shared.ask = askBeforeReceive
    }

    /// Zmiana stanu z dowolnego wątku – wykonuje się na głównym.
    func post(_ change: @escaping (AppModel) -> Void) {
        DispatchQueue.main.async { change(self) }
    }

    func becameActive() {
        UIApplication.shared.isIdleTimerDisabled = true      // ekran nie gaśnie podczas odbioru
        wifiAddress = AppModel.currentWifiAddress()
        refreshPhotoStatus()
        if photoStatus == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async { self.photoStatus = status }
            }
        }
        if saver == nil {
            saver = PhotoSaver(model: self)
        }
        if receiver == nil, let saver = saver {
            receiver = Receiver(model: self, saver: saver)
        }
        receiver?.start()
    }

    func answerOffer(_ accept: Bool) {
        guard let offer = pendingOffer else { return }
        pendingOffer = nil
        offer.answer(accept)
    }

    func randomizeName() {
        deviceName = NameGenerator.random()
    }

    func refreshPhotoStatus() {
        photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func resetCounters() {
        received = 0
        saved = 0
        failed = 0
        bytes = 0
        speed = 0
        currentFile = ""
        lastError = ""
        if connections == 0 {
            phase = .waiting
        }
    }

    var canSave: Bool {
        photoStatus == .authorized || photoStatus == .limited ||
            PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
    }

    /// Adres IPv4 telefonu w sieci Wi-Fi.
    static func currentWifiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let sa = ptr.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
            }
        }
        return address
    }
}
