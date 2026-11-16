import Foundation
import Combine
import AppKit

struct ColorPreset: Identifiable {
    let id = UUID()
    let name: String
    let hex: String
    let r: Double
    let g: Double
    let b: Double
}

struct DiscoveredDevice: Identifiable, Hashable {
    var id: String { address }
    let name: String
    let address: String
    let rssi: Int
    let isCompatible: Bool
}

class LampController: ObservableObject {
    @Published var configuredAddress: String? = nil
    @Published var isConnected: Bool = false
    @Published var isOn: Bool = true
    @Published var brightness: Double = 100
    @Published var temperature: Double = 2700
    @Published var hue: Double = 0
    @Published var statusText: String = "Connexion..."
    
    // MARK: - Découverte & Gestion Dispositifs
    @Published var isScanning: Bool = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var scanMessage: String? = nil
    @Published var showDeviceManager: Bool = false
    
    // MARK: - Moteur AutoLight (Webcam)
    @Published var autoLight = AutoLightEngine()
    
    private var cancellables = Set<AnyCancellable>()
    private var daemonProcess: Process?
    private var healthCheckTimer: Timer?
    private var throttleWorkItem: DispatchWorkItem?
    private var lastSendTimestamp: TimeInterval = 0
    
    let presets: [ColorPreset] = [
        ColorPreset(name: "Rouge", hex: "#FF3B30", r: 1.0, g: 0.23, b: 0.19),
        ColorPreset(name: "Orange", hex: "#FF9500", r: 1.0, g: 0.58, b: 0.0),
        ColorPreset(name: "Jaune", hex: "#FFCC00", r: 1.0, g: 0.8, b: 0.0),
        ColorPreset(name: "Vert", hex: "#34C759", r: 0.2, g: 0.78, b: 0.35),
        ColorPreset(name: "Cyan", hex: "#32ADE6", r: 0.2, g: 0.68, b: 0.9),
        ColorPreset(name: "Bleu", hex: "#007AFF", r: 0.0, g: 0.48, b: 1.0),
        ColorPreset(name: "Violet", hex: "#AF52DE", r: 0.69, g: 0.32, b: 0.87),
        ColorPreset(name: "Rose", hex: "#FF2D55", r: 1.0, g: 0.18, b: 0.33)
    ]
    
    var temperatureLabel: String {
        if temperature < 3400 {
            return "Chaud"
        } else if temperature < 5000 {
            return "Neutre"
        } else {
            return "Froid"
        }
    }
    
    var statusIcon: String {
        if !isConnected {
            return "lightbulb.slash"
        } else if isOn {
            return "lightbulb.fill"
        } else {
            return "lightbulb"
        }
    }
    
    init() {
        loadConfiguredAddress()
        startHealthTimer()
        
        // Configuration callbacks AutoLight
        autoLight.getCurrentLampBrightness = { [weak self] in
            return self?.brightness ?? 50.0
        }
        autoLight.applyLampBrightness = { [weak self] newB in
            DispatchQueue.main.async {
                self?.setBrightness(newB, immediate: true)
            }
        }
        
        // Propagation des changements AutoLight pour SwiftUI
        autoLight.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        if configuredAddress != nil {
            ensureDaemonRunning()
        } else {
            showDeviceManager = true
            statusText = "Non configuré"
        }
    }
    
    deinit {
        shutdown()
    }
    
    // MARK: - Configuration Dispositif
    
    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lumenbar_config.json")
    }
    
    private var legacyConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gdansk_config.json")
    }
    
    func loadConfiguredAddress() {
        for url in [configURL, legacyConfigURL] {
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let addr = json["address"] as? String, !addr.isEmpty {
                self.configuredAddress = addr
                return
            }
        }
        self.configuredAddress = nil
    }
    
    func pairDevice(address: String) {
        let cleanAddr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAddr.isEmpty else { return }
        
        let dict: [String: Any] = ["address": cleanAddr]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: configURL)
        }
        
        DispatchQueue.main.async {
            self.configuredAddress = cleanAddr
            self.showDeviceManager = false
            self.discoveredDevices.removeAll()
            self.scanMessage = nil
            self.statusText = "Connexion..."
            self.ensureDaemonRunning()
        }
    }
    
    func forgetDevice() {
        // 1. Éteindre et couper le démon
        shutdown()
        
        // 2. Supprimer la configuration
        try? FileManager.default.removeItem(at: configURL)
        try? FileManager.default.removeItem(at: legacyConfigURL)
        
        DispatchQueue.main.async {
            self.configuredAddress = nil
            self.isConnected = false
            self.statusText = "Non configuré"
            self.showDeviceManager = true
            self.scanForDevices()
        }
    }
    
    func scanForDevices() {
        guard !isScanning else { return }
        isScanning = true
        scanMessage = "Recherche Bluetooth en cours (6s)..."
        discoveredDevices.removeAll()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Si le démon tourne, le stopper pour que la lampe émette ses annonces
            _ = self.sendSocketCommand("stop")
            
            let python = self.resolvePythonPath()
            let script = self.resolveScriptPath()
            
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = [script, "scan_json"]
            
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            
            do {
                try p.run()
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8),
                   let range = output.range(of: "JSON:") {
                    let jsonStr = String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let jsonData = jsonStr.data(using: .utf8),
                       let list = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                        var parsed: [DiscoveredDevice] = []
                        for item in list {
                            let name = item["name"] as? String ?? "Inconnu"
                            let addr = item["address"] as? String ?? ""
                            let rssi = item["rssi"] as? Int ?? -99
                            let compat = item["is_compatible"] as? Bool ?? false
                            if !addr.isEmpty {
                                parsed.append(DiscoveredDevice(name: name, address: addr, rssi: rssi, isCompatible: compat))
                            }
                        }
                        DispatchQueue.main.async {
                            self.discoveredDevices = parsed
                            self.isScanning = false
                            if parsed.isEmpty {
                                self.scanMessage = "Aucun luminaire détecté. Vérifiez que la lampe est sous tension et déconnectée du smartphone."
                            } else {
                                self.scanMessage = "\(parsed.count) équipement(s) trouvé(s)"
                            }
                        }
                        return
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.scanMessage = "Erreur pendant le scan: \(error.localizedDescription)"
                    self.isScanning = false
                }
                return
            }
            
            DispatchQueue.main.async {
                self.isScanning = false
                self.scanMessage = "Aucun dispositif trouvé."
            }
        }
    }
    
    // MARK: - Process & Daemon Lifecycle
    
    private func resolvePythonPath() -> String {
        let candidates = [
            "/opt/homebrew/anaconda3/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/usr/bin/python3"
    }
    
    private func resolveScriptPath() -> String {
        for name in ["lumenbar", "gdansk"] {
            if let bundlePath = Bundle.main.path(forResource: name, ofType: "py") {
                return bundlePath
            }
        }
        let homeCandidates = ["lumenbar.py", "gdansk.py"]
        for name in homeCandidates {
            let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "/Users/yoto/lumenbar.py"
    }
    
    func ensureDaemonRunning() {
        loadConfiguredAddress()
        guard let addr = configuredAddress, !addr.isEmpty else {
            DispatchQueue.main.async {
                self.isConnected = false
                self.statusText = "Non configuré"
                self.showDeviceManager = true
            }
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 1. Déjà actif ?
            if let pong = self.sendSocketCommand("ping") {
                if pong.contains("READY") {
                    DispatchQueue.main.async {
                        self.isConnected = true
                        self.statusText = "Connecté"
                    }
                    self.fetchStatus()
                    return
                } else if pong.contains("PONG") {
                    DispatchQueue.main.async {
                        self.isConnected = false
                        self.statusText = "Connexion Bluetooth..."
                    }
                }
            }
            
            // 2. Nettoyage socket orphelin si besoin
            if FileManager.default.fileExists(atPath: "/tmp/lumenbar.sock") {
                try? FileManager.default.removeItem(atPath: "/tmp/lumenbar.sock")
            }
            if FileManager.default.fileExists(atPath: "/tmp/gdansk.sock") {
                try? FileManager.default.removeItem(atPath: "/tmp/gdansk.sock")
            }
            
            DispatchQueue.main.async {
                self.isConnected = false
                self.statusText = "Démarrage du démon..."
            }
            
            let python = self.resolvePythonPath()
            let script = self.resolveScriptPath()
            
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = [script, "_daemon_worker"]
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            p.environment = env
            
            let logPath = "/tmp/lumenbar_daemon.log"
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            if let logHandle = FileHandle(forWritingAtPath: logPath) {
                logHandle.seekToEndOfFile()
                p.standardOutput = logHandle
                p.standardError = logHandle
            }
            
            do {
                try p.run()
                self.daemonProcess = p
            } catch {
                DispatchQueue.main.async {
                    self.statusText = "Erreur: \(error.localizedDescription)"
                }
                return
            }
            
            // Attente active du socket et de la connexion BLE (jusqu'à 20s)
            for _ in 0..<80 {
                Thread.sleep(forTimeInterval: 0.25)
                if let pong = self.sendSocketCommand("ping") {
                    if pong.contains("READY") {
                        DispatchQueue.main.async {
                            self.isConnected = true
                            self.statusText = "Connecté"
                        }
                        self.fetchStatus()
                        return
                    } else if pong.contains("PONG") {
                        DispatchQueue.main.async {
                            self.isConnected = false
                            self.statusText = "Connexion Bluetooth..."
                        }
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.statusText = "Lampe hors de portée ou occupée"
            }
        }
    }
    
    private func startHealthTimer() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.configuredAddress != nil else { return }
            DispatchQueue.global(qos: .utility).async {
                let pong = self.sendSocketCommand("ping")
                DispatchQueue.main.async {
                    if let p = pong {
                        if p.contains("READY") {
                            if !self.isConnected {
                                self.isConnected = true
                                self.statusText = "Connecté"
                                self.fetchStatus()
                            }
                        } else if p.contains("CONNECTING") {
                            self.isConnected = false
                            self.statusText = "Connexion Bluetooth..."
                        }
                    } else {
                        if self.isConnected {
                            self.isConnected = false
                            self.statusText = "Reconnexion..."
                            self.ensureDaemonRunning()
                        }
                    }
                }
            }
        }
    }
    
    func shutdown() {
        autoLight.stop()
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        
        // Éteindre la lampe automatiquement à la fermeture
        _ = sendSocketCommand("off")
        Thread.sleep(forTimeInterval: 0.15)
        
        _ = sendSocketCommand("stop")
        
        if let p = daemonProcess, p.isRunning {
            p.terminate()
        }
        daemonProcess = nil
        
        if FileManager.default.fileExists(atPath: "/tmp/lumenbar.sock") {
            try? FileManager.default.removeItem(atPath: "/tmp/lumenbar.sock")
        }
        if FileManager.default.fileExists(atPath: "/tmp/gdansk.sock") {
            try? FileManager.default.removeItem(atPath: "/tmp/gdansk.sock")
        }
    }
    
    func quitApp() {
        shutdown()
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - Unix Socket Client
    
    @discardableResult
    func sendSocketCommand(_ cmd: String) -> String? {
        let socketCandidates = ["/tmp/lumenbar.sock", "/tmp/gdansk.sock"]
        for path in socketCandidates {
            if let res = trySendSocket(cmd, path: path) {
                return res
            }
        }
        return nil
    }

    private func trySendSocket(_ cmd: String, path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), path, 104)
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, addrLen)
            }
        }
        guard res == 0 else { return nil }

        let msg = cmd.hasSuffix("\n") ? cmd : cmd + "\n"
        _ = msg.utf8CString.withUnsafeBufferPointer { buf in
            send(fd, buf.baseAddress, buf.count - 1, 0)
        }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = recv(fd, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return nil }
        return String(bytes: buffer[..<bytesRead], encoding: .utf8)
    }
    
    func sendThrottled(_ cmd: String, minInterval: TimeInterval = 0.08) {
        throttleWorkItem?.cancel()
        let now = Date().timeIntervalSince1970
        let elapsed = now - lastSendTimestamp
        if elapsed >= minInterval {
            lastSendTimestamp = now
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.sendSocketCommand(cmd)
            }
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lastSendTimestamp = Date().timeIntervalSince1970
                self.sendSocketCommand(cmd)
            }
            throttleWorkItem = work
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (minInterval - elapsed), execute: work)
        }
    }
    
    func sendImmediate(_ cmd: String) {
        throttleWorkItem?.cancel()
        lastSendTimestamp = Date().timeIntervalSince1970
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.sendSocketCommand(cmd)
        }
    }
    
    // MARK: - Actions Contrôles
    
    func fetchStatus() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let resp = self.sendSocketCommand("status_json") else { return }
            if let range = resp.range(of: "JSON:") {
                let jsonString = String(resp[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let data = jsonString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async {
                        if let p = json["power"] as? Bool { self.isOn = p }
                        if let d = json["dim"] as? Double { self.brightness = d }
                        else if let d = json["dim"] as? Int { self.brightness = Double(d) }
                        if let t = json["temp"] as? Double { self.temperature = t }
                        else if let t = json["temp"] as? Int { self.temperature = Double(t) }
                        if let h = json["hue"] as? Double { self.hue = h }
                        else if let h = json["hue"] as? Int { self.hue = Double(h) }
                        self.isConnected = true
                        self.statusText = "Connecté"
                    }
                }
            }
        }
    }
    
    func togglePower() {
        isOn.toggle()
        if !isOn {
            sendImmediate("off")
        } else {
            sendImmediate("on")
        }
    }
    
    func userSetBrightness(_ val: Double, immediate: Bool = false) {
        if autoLight.isEnabled {
            autoLight.targetComfort = val
        }
        setBrightness(val, immediate: immediate)
    }
    
    func setBrightness(_ val: Double, immediate: Bool = false) {
        brightness = val
        if !isOn { isOn = true }
        let pct = Int(round(val))
        if immediate {
            sendImmediate("dim \(pct)")
        } else {
            sendThrottled("dim \(pct)")
        }
    }
    
    func setTemperature(_ val: Double, immediate: Bool = false) {
        temperature = val
        if !isOn { isOn = true }
        let k = Int(round(val))
        if immediate {
            sendImmediate("temp \(k)")
        } else {
            sendThrottled("temp \(k)")
        }
    }
    
    func setHue(_ val: Double, immediate: Bool = false) {
        hue = val
        if !isOn { isOn = true }
        let deg = Int(round(val))
        if immediate {
            sendImmediate("hue \(deg)")
        } else {
            sendThrottled("hue \(deg)")
        }
    }
    
    func setColor(preset: ColorPreset) {
        if !isOn { isOn = true }
        sendImmediate("hex \(preset.hex)")
    }
}
