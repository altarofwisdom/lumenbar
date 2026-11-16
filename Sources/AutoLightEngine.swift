import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import Combine

/// Représentation d'une caméra disponible (physique ou virtuelle)
struct CameraDeviceItem: Identifiable, Hashable {
    let id: String
    let name: String
    let isVirtual: Bool
}

/// Moteur AutoLight : Régulation automatique de l'éclairage par webcam
/// avec découplage de rétroaction optique (Feed-Forward Cancellation).
class AutoLightEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    // MARK: - Propriétés observables
    
    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }
    
    /// Caméras vidéo disponibles
    @Published var availableCameras: [CameraDeviceItem] = []
    
    /// ID de la caméra sélectionnée
    @Published var selectedCameraID: String = "" {
        didSet {
            if oldValue != selectedCameraID && !selectedCameraID.isEmpty {
                switchCamera(to: selectedCameraID)
                saveCameraPreference(selectedCameraID)
            }
        }
    }
    
    /// Confort lumineux souhaité par l'utilisateur (0% à 100%)
    @Published var targetComfort: Double = 60.0
    
    /// Lumière ambiante externe estimée (hors contribution de la lampe, 0% à 100%)
    @Published var estimatedExternalLux: Double = 50.0
    
    /// Luminance brute totale mesurée par la webcam (0% à 100%)
    @Published var rawCameraLuma: Double = 50.0
    
    /// Coefficient de couplage optique α (part du flux de la lampe renvoyé sur la caméra)
    @Published var couplingAlpha: Double = 0.25
    
    /// État d'étalonnage en cours
    @Published var isCalibrating: Bool = false
    
    /// Message d'état pour l'interface
    @Published var statusMessage: String = "Inactif"
    
    /// Autorisation d'accès à la caméra
    @Published var cameraAuthorized: Bool = false
    
    // MARK: - Dépendances & Callbacks
    
    /// Lecture de la luminosité actuelle de la lampe
    var getCurrentLampBrightness: (() -> Double)?
    
    /// Envoi de la consigne de luminosité à la lampe
    var applyLampBrightness: ((Double) -> Void)?
    
    // MARK: - Capture AVFoundation
    
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.altarofwisdom.lumenbar.autolight", qos: .userInitiated)
    
    private var lastSampleTimestamp: CFAbsoluteTime = 0
    private let sampleInterval: CFAbsoluteTime = 1.8 // Échantillonnage toutes les 1.8 secondes
    
    // MARK: - Filtre & Régulation
    
    private var smoothedExternalLux: Double = 50.0
    private let emaFactor: Double = 0.80 // Filtre passe-bas (lissage sur ~8 secondes)
    private let deadband: Double = 4.0   // Seuil d'hystérésis (pas d'action si écart < 4%)
    private let maxStepPerCycle: Double = 2.5 // Rampe douce max par cycle
    
    // MARK: - Initialisation
    
    override init() {
        super.init()
        checkCameraAuthorization()
        refreshAvailableCameras()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onDeviceNotification),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onDeviceNotification),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
    }
    
    @objc private func onDeviceNotification() {
        refreshAvailableCameras()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stop()
    }
    
    // MARK: - Gestion & Sélection Caméra
    
    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lumenbar_config.json")
    }
    
    private func loadSavedCameraID() -> String? {
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json["camera_id"] as? String
        }
        return nil
    }
    
    private func saveCameraPreference(_ id: String) {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = json
        }
        dict["camera_id"] = id
        if let updated = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? updated.write(to: configURL)
        }
    }
    
    func refreshAvailableCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        
        let virtualKeywords = ["virtual", "obs", "iriun", "camo", "droidcam", "splitcam", "ndi", "loopback", "dummy"]
        let list = discovery.devices.map { dev -> CameraDeviceItem in
            let lower = dev.localizedName.lowercased()
            let isVirt = virtualKeywords.contains { lower.contains($0) }
            return CameraDeviceItem(id: dev.uniqueID, name: dev.localizedName, isVirtual: isVirt)
        }
        
        DispatchQueue.main.async {
            self.availableCameras = list
            let saved = self.loadSavedCameraID()
            
            if let s = saved, list.contains(where: { $0.id == s }) {
                if self.selectedCameraID != s {
                    self.selectedCameraID = s
                }
            } else if self.selectedCameraID.isEmpty || !list.contains(where: { $0.id == self.selectedCameraID }) {
                // Préférer la première caméra physique si possible
                if let physical = list.first(where: { !$0.isVirtual }) {
                    self.selectedCameraID = physical.id
                } else if let first = list.first {
                    self.selectedCameraID = first.id
                }
            }
        }
    }
    
    func switchCamera(to id: String) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            guard let device = AVCaptureDevice(uniqueID: id) else { return }
            
            self.captureSession.beginConfiguration()
            if let currentInput = self.captureSession.inputs.first {
                self.captureSession.removeInput(currentInput)
            }
            if let newInput = try? AVCaptureDeviceInput(device: device), self.captureSession.canAddInput(newInput) {
                self.captureSession.addInput(newInput)
            }
            self.captureSession.commitConfiguration()
            
            DispatchQueue.main.async {
                self.statusMessage = "Caméra : \(device.localizedName)"
                if self.isEnabled {
                    self.calibrateCoupling()
                }
            }
        }
    }
    
    // MARK: - Autorisations Caméra
    
    func checkCameraAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async {
                self.cameraAuthorized = true
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.cameraAuthorized = granted
                    if !granted {
                        self?.statusMessage = "Accès caméra refusé"
                    }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.cameraAuthorized = false
                self.statusMessage = "Accès caméra non autorisé"
            }
        @unknown default:
            break
        }
    }
    
    // MARK: - Cycle de vie du moteur
    
    func start() {
        guard !captureSession.isRunning else { return }
        checkCameraAuthorization()
        
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.setupCaptureSession()
            self.captureSession.startRunning()
            
            DispatchQueue.main.async {
                self.statusMessage = "AutoLight actif"
                // Lancer un étalonnage rapide à la première activation
                self.calibrateCoupling()
            }
        }
    }
    
    func stop() {
        guard captureSession.isRunning else { return }
        captureQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            DispatchQueue.main.async {
                self?.statusMessage = "AutoLight inactif"
            }
        }
    }
    
    private func setupCaptureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .low // Très faible résolution pour économie CPU/GPU
        
        // Sélection de la webcam
        var device: AVCaptureDevice? = nil
        if !selectedCameraID.isEmpty {
            device = AVCaptureDevice(uniqueID: selectedCameraID)
        }
        if device == nil {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external],
                mediaType: .video,
                position: .unspecified
            )
            device = discovery.devices.first
        }
        
        guard let validDevice = device else {
            captureSession.commitConfiguration()
            DispatchQueue.main.async {
                self.statusMessage = "Aucune webcam détectée"
            }
            return
        }
        
        // Entrée
        if let currentInput = captureSession.inputs.first {
            captureSession.removeInput(currentInput)
        }
        if let input = try? AVCaptureDeviceInput(device: validDevice), captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        
        // Sortie flux
        if captureSession.outputs.isEmpty {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
            }
        }
        
        captureSession.commitConfiguration()
    }
    
    // MARK: - Étalonnage automatique du couplage optique (α)
    
    func calibrateCoupling() {
        guard !isCalibrating else { return }
        isCalibrating = true
        statusMessage = "Étalonnage optique..."
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let initialLamp = self.getCurrentLampBrightness?() ?? 50.0
            // Attente de stabilisation
            Thread.sleep(forTimeInterval: 0.8)
            let m0 = self.rawCameraLuma
            
            // Appliquer un échelon de luminosité
            let deltaB: Double = (initialLamp > 75.0) ? -20.0 : 20.0
            let testLamp = max(10.0, min(100.0, initialLamp + deltaB))
            self.applyLampBrightness?(testLamp)
            
            // Attente réponse de la lampe et du capteur
            Thread.sleep(forTimeInterval: 1.5)
            let m1 = self.rawCameraLuma
            
            // Calcul du ratio couplage α = |ΔM| / |ΔB|
            let observedDelta = abs(m1 - m0)
            let appliedDelta = abs(testLamp - initialLamp)
            var calculatedAlpha = (appliedDelta > 5.0) ? (observedDelta / appliedDelta) : 0.25
            
            // Bornage de sécurité pour α (entre 0.05 et 0.65)
            calculatedAlpha = max(0.05, min(0.65, calculatedAlpha))
            
            // Rétablissement de la lampe
            self.applyLampBrightness?(initialLamp)
            Thread.sleep(forTimeInterval: 0.5)
            
            DispatchQueue.main.async {
                self.couplingAlpha = calculatedAlpha
                self.isCalibrating = false
                self.statusMessage = String(format: "Étalonné (α = %.2f)", calculatedAlpha)
            }
        }
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isEnabled, !isCalibrating else { return }
        
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSampleTimestamp >= sampleInterval else { return }
        lastSampleTimestamp = now
        
        // 1. Calcul de la luminance de la scène (0 à 100)
        let measuredLuma = computeSceneLuma(sampleBuffer: sampleBuffer)
        
        // 2. Découplage de la contribution de la lampe (Soustraction feed-forward)
        let currentLamp = getCurrentLampBrightness?() ?? 50.0
        let lampContribution = currentLamp * couplingAlpha
        let rawExternal = max(0.0, min(100.0, measuredLuma - lampContribution))
        
        // 3. Filtrage passe-bas (EMA) pour amortir les passages passagers
        smoothedExternalLux = (emaFactor * smoothedExternalLux) + ((1.0 - emaFactor) * rawExternal)
        
        DispatchQueue.main.async {
            self.rawCameraLuma = measuredLuma
            self.estimatedExternalLux = self.smoothedExternalLux
        }
        
        // 4. Régulation en boucle fermée
        computeAndApplyAdjustment(externalLux: smoothedExternalLux, currentLamp: currentLamp)
    }
    
    // MARK: - Analyse de Luminance Ultra-légère (Pixels BGRA)
    
    private func computeSceneLuma(sampleBuffer: CMSampleBuffer) -> Double {
        // Tenter d'abord la métrique APEX BrightnessValue depuis les métadonnées EXIF si disponibles
        if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldPropagate) as? [String: Any],
           let exif = attachments["{Exif}"] as? [String: Any],
           let bv = exif[kCGImagePropertyExifBrightnessValue as String] as? Double {
            // Normalisation APEX (-5 à +12 EV) sur 0 à 100%
            let norm = ((bv + 5.0) / 15.0) * 100.0
            return max(0.0, min(100.0, norm))
        }
        
        // Analyse directe de la matrice de pixels centrale (zone utile 50% centrale)
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return 50.0 }
        
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else { return 50.0 }
        
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        
        let startX = width / 4
        let endX = (width * 3) / 4
        let startY = height / 4
        let endY = (height * 3) / 4
        
        let stepX = 16 // Échantillonnage discret par pas de 16 pixels
        let stepY = 16
        
        var totalLuma: Double = 0.0
        var count: Double = 0.0
        
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        for y in stride(from: startY, to: endY, by: stepY) {
            let rowOffset = y * bytesPerRow
            for x in stride(from: startX, to: endX, by: stepX) {
                let pixelOffset = rowOffset + (x * 4)
                let b = Double(ptr[pixelOffset])
                let g = Double(ptr[pixelOffset + 1])
                let r = Double(ptr[pixelOffset + 2])
                
                // Formule de luminance ITU-R BT.601
                let yVal = (0.299 * r) + (0.587 * g) + (0.114 * b)
                totalLuma += yVal
                count += 1.0
            }
        }
        
        guard count > 0 else { return 50.0 }
        let averageLuma = (totalLuma / count) / 255.0 * 100.0
        return averageLuma
    }
    
    // MARK: - Algorithme de Régulation Douce
    
    private func computeAndApplyAdjustment(externalLux: Double, currentLamp: Double) {
        // Si l'extérieur est très lumineux (ex: 80%), la lampe compense au minimum
        // Si l'extérieur est sombre (ex: 10%), la lampe augmente pour compenser
        // Consigne désirée = f(targetComfort, externalLux)
        let deficit = targetComfort - externalLux
        var desiredLamp = targetComfort + (deficit * 0.8)
        desiredLamp = max(10.0, min(100.0, desiredLamp))
        
        let delta = desiredLamp - currentLamp
        
        // 1. Bande morte (Deadband) : ignore les micro-écarts (< 4%)
        if abs(delta) < deadband {
            DispatchQueue.main.async {
                self.statusMessage = "Ambiance stable"
            }
            return
        }
        
        // 2. Limitation de rampe (Slew Rate Limiter) : variation progressive de 2.5% max
        let step = max(-maxStepPerCycle, min(maxStepPerCycle, delta))
        let nextBrightness = max(10.0, min(100.0, currentLamp + step))
        
        DispatchQueue.main.async {
            self.statusMessage = (delta > 0) ? "Compensation (+)..." : "Compensation (-)..."
        }
        
        // 3. Application immédiate à la lampe
        applyLampBrightness?(nextBrightness)
    }
}
