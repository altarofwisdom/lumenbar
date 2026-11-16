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
    
    /// Coefficient de couplage optique G (pente de variation % luma / % lampe)
    @Published var couplingAlpha: Double = 0.25
    
    /// Seuil d'éclairage minimal émis par la lampe à 1% (Low-End Trim physique)
    @Published var minStepLuma: Double = 5.0
    
    /// État d'étalonnage en cours
    @Published var isCalibrating: Bool = false
    
    /// Message d'état pour l'interface
    @Published var statusMessage: String = "Inactif"
    
    /// Autorise l'extinction et le rallumage automatique de la lampe si la lumière naturelle suffit
    @Published var autoPowerToggle: Bool = true
    
    /// Autorisation d'accès à la caméra
    @Published var cameraAuthorized: Bool = false
    
    // MARK: - Dépendances & Callbacks
    
    /// Lecture de la luminosité actuelle de la lampe
    var getCurrentLampBrightness: (() -> Double)?
    
    /// Lecture de l'état d'allumage (ON/OFF)
    var getIsLampOn: (() -> Bool)?
    
    /// Commande d'allumage/extinction automatique de la lampe
    var applyLampPower: ((Bool) -> Void)?
    
    /// Envoi de la consigne de luminosité à la lampe
    var applyLampBrightness: ((Double) -> Void)?
    
    /// Commande directe synchrone (allumage/extinction + luminosité) pour l'étalonnage
    var setLampStateDirect: ((Bool, Double) -> Void)?
    
    // MARK: - Capture AVFoundation
    
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.altarofwisdom.lumenbar.autolight", qos: .userInitiated)
    
    private var lastSampleTimestamp: CFAbsoluteTime = 0
    private let sampleInterval: CFAbsoluteTime = 1.8 // Échantillonnage toutes les 1.8 secondes
    
    private var recentLumaSamples: [Double] = []
    private var latestLuma: Double = 50.0
    private let lumaLock = NSLock()
    
    // MARK: - Filtre & Régulation
    
    private var smoothedExternalLux: Double = 50.0
    private let emaFactor: Double = 0.80 // Filtre passe-bas (lissage sur ~8 secondes)
    private let deadband: Double = 1.5   // Seuil d'hystérésis (pas d'action si écart < 1.5%)
    private let maxStepPerCycle: Double = 1.0 // Rampe ultra-douce de 1% max par cycle (1.8s)
    
    private var excessLightCycleCount: Int = 0
    private let excessCyclesRequired: Int = 2 // ~3.6s de confirmation pour extinction auto
    private let turnOnHysteresis: Double = 1.5 // Déficit minimum de 1.5% pour amorcer l'allumage
    private var manualOffCooldownUntil: Date = Date.distantPast
    
    func userDidManuallyTurnOff() {
        manualOffCooldownUntil = Date().addingTimeInterval(120.0)
    }
    
    func userDidManuallyTurnOn() {
        manualOffCooldownUntil = Date.distantPast
    }
    
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
                self.activeDevice = device
                self.lockExposureIfPossible()
            }
            self.captureSession.commitConfiguration()
            
            DispatchQueue.main.async {
                self.statusMessage = L10n.cameraSelected(name: device.localizedName)
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
                        self?.statusMessage = L10n.cameraPermissionDenied
                    }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.cameraAuthorized = false
                self.statusMessage = L10n.cameraNotAuthorized
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
            self.lockExposureIfPossible()
            
            DispatchQueue.main.async {
                self.statusMessage = L10n.autoLightActive
            }
        }
    }
    
    func stop() {
        guard captureSession.isRunning else { return }
        unlockExposureToContinuous()
        captureQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            DispatchQueue.main.async {
                self?.statusMessage = L10n.autoLightInactive
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
                self.statusMessage = L10n.noWebcamDetected
            }
            return
        }
        
        // Entrée
        if let currentInput = captureSession.inputs.first {
            captureSession.removeInput(currentInput)
        }
        if let input = try? AVCaptureDeviceInput(device: validDevice), captureSession.canAddInput(input) {
            captureSession.addInput(input)
            self.activeDevice = validDevice
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
    
    // MARK: - Contrôle matériel de l'exposition (Norme LBNL / IES)
    
    private var activeDevice: AVCaptureDevice?
    
    private func lockExposureIfPossible() {
        guard let dev = activeDevice else { return }
        do {
            try dev.lockForConfiguration()
            if dev.isExposureModeSupported(.locked) {
                dev.exposureMode = .locked
            }
            dev.unlockForConfiguration()
        } catch {
            print("Failed to lock exposure: \(error)")
        }
    }
    
    private func unlockExposureToContinuous() {
        guard let dev = activeDevice else { return }
        do {
            try dev.lockForConfiguration()
            if dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposureMode = .continuousAutoExposure
            }
            dev.unlockForConfiguration()
        } catch {
            print("Failed to unlock exposure: \(error)")
        }
    }
    
    // MARK: - Étalonnage en Boucle Fermée (Norme LBNL / Rubinstein & IES)
    
    func calibrateCoupling() {
        guard !isCalibrating else { return }
        DispatchQueue.main.async {
            self.isCalibrating = true
            self.statusMessage = L10n.calibratingLock
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            defer {
                DispatchQueue.main.async {
                    self.isCalibrating = false
                }
            }
            
            // 0. Mémorisation de l'état initial de la lampe
            let initialWasOn = self.getIsLampOn?() ?? true
            let initialBrightness = self.getCurrentLampBrightness?() ?? 50.0
            
            // 1. ÉTAPE 1 : Stabilisation sous lumière ambiante réelle (écrans, autres lumières) puis verrouillage matériel
            DispatchQueue.main.async {
                self.statusMessage = L10n.calibratingLock
            }
            self.unlockExposureToContinuous()
            Thread.sleep(forTimeInterval: 1.2)
            self.lockExposureIfPossible()
            Thread.sleep(forTimeInterval: 0.3)
            
            // 2. ÉTAPE 2 : Mesure de l'ambiance pure sans cette lampe (Lampe éteinte, B = 0)
            DispatchQueue.main.async {
                self.statusMessage = L10n.calibratingOff
            }
            self.setLampStateDirect?(false, 0.0)
            let sOff = self.measureAverageLuma(settleDuration: 1.3, sampleDuration: 0.6)
            
            // 3. ÉTAPE 3 : Mesure du palier minimal réel de la lampe à 1% (Low-End Trim physique)
            DispatchQueue.main.async {
                self.statusMessage = L10n.calibratingMin
            }
            self.setLampStateDirect?(true, 1.0)
            let sMin = self.measureAverageLuma(settleDuration: 1.3, sampleDuration: 0.6)
            let measuredMinStep = max(0.5, sMin - sOff)
            
            // 4. ÉTAPE 4 : Mesure de la réponse optique à 80% (Pente de variation)
            DispatchQueue.main.async {
                self.statusMessage = L10n.calibratingOn
            }
            self.setLampStateDirect?(true, 80.0)
            let s80 = self.measureAverageLuma(settleDuration: 1.3, sampleDuration: 0.6)
            
            // 5. ÉTAPE 5 : Calcul de la pente de transfert G = ΔS / ΔB sur la plage utile (1% -> 80%)
            let deltaS = s80 - sMin
            let deltaB = 79.0
            
            var calculatedGain: Double
            if deltaS > 1.0 {
                calculatedGain = max(0.05, min(0.85, deltaS / deltaB))
            } else {
                calculatedGain = 0.25 // Repli sécurisé si la webcam ne reçoit pas le faisceau direct
            }
            
            // 6. ÉTAPE 6 : Rétablissement propre de l'état initial
            if initialWasOn {
                self.setLampStateDirect?(true, initialBrightness)
            } else {
                self.setLampStateDirect?(false, 0.0)
            }
            Thread.sleep(forTimeInterval: 0.3)
            
            DispatchQueue.main.async {
                self.minStepLuma = measuredMinStep
                self.couplingAlpha = calculatedGain
                self.smoothedExternalLux = sOff
                self.estimatedExternalLux = sOff
                self.statusMessage = L10n.calibrated(alpha: calculatedGain, minStep: measuredMinStep)
            }
        }
    }
    
    private func measureAverageLuma(settleDuration: TimeInterval, sampleDuration: TimeInterval) -> Double {
        // Attente de stabilisation de la commande BLE et du capteur vidéo
        Thread.sleep(forTimeInterval: settleDuration)
        
        // Réinitialiser les échantillons pour capturer la fenêtre stable
        lumaLock.lock()
        recentLumaSamples.removeAll()
        lumaLock.unlock()
        
        Thread.sleep(forTimeInterval: sampleDuration)
        
        lumaLock.lock()
        defer { lumaLock.unlock() }
        
        if !recentLumaSamples.isEmpty {
            return recentLumaSamples.reduce(0.0, +) / Double(recentLumaSamples.count)
        }
        return latestLuma
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isEnabled else { return }
        
        let now = CFAbsoluteTimeGetCurrent()
        let interval = isCalibrating ? 0.25 : sampleInterval
        guard now - lastSampleTimestamp >= interval else { return }
        lastSampleTimestamp = now
        
        // 1. Calcul de la luminance de la scène (avec exposition verrouillée)
        let measuredLuma = computeSceneLuma(sampleBuffer: sampleBuffer)
        
        lumaLock.lock()
        latestLuma = measuredLuma
        recentLumaSamples.append(measuredLuma)
        if recentLumaSamples.count > 15 {
            recentLumaSamples.removeFirst()
        }
        lumaLock.unlock()
        
        DispatchQueue.main.async {
            self.rawCameraLuma = measuredLuma
        }
        
        // Pendant l'étalonnage, ne pas réguler la lampe
        guard !isCalibrating else { return }
        
        // 2. Lissage passe-bas (EMA) de la lumière totale perçue S(t)
        smoothedExternalLux = (emaFactor * smoothedExternalLux) + ((1.0 - emaFactor) * measuredLuma)
        
        DispatchQueue.main.async {
            self.estimatedExternalLux = self.smoothedExternalLux
        }
        
        // 3. Régulation en boucle fermée LBNL
        let currentLamp = getCurrentLampBrightness?() ?? 50.0
        computeAndApplyClosedLoop(sceneLuma: smoothedExternalLux, currentLamp: currentLamp)
    }
    
    // MARK: - Analyse de Luminance (Pixels BGRA)
    
    private func computeSceneLuma(sampleBuffer: CMSampleBuffer) -> Double {
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
    
    // MARK: - Régulation en Boucle Fermée (Norme LBNL / Rubinstein & IES avec Low-End Trim)
    
    private func computeAndApplyClosedLoop(sceneLuma: Double, currentLamp: Double) {
        let isLampOn = getIsLampOn?() ?? true
        
        // Erreur de consigne = Confort souhaité - Lumière totale actuelle mesurée
        let error = targetComfort - sceneLuma
        
        // -------------------------------------------------------------
        // CAS 1 : La lampe est actuellement ÉTEINTE (Veille AutoLight)
        // -------------------------------------------------------------
        if !isLampOn {
            if Date() < manualOffCooldownUntil {
                DispatchQueue.main.async {
                    self.statusMessage = L10n.manuallyOffPause
                }
                return
            }
            
            // Seuil d'allumage calibré sur la marche minimale physique de la lampe :
            // Pour éviter l'overshoot et le pompage (hunting), on n'allume que si le besoin
            // de lumière dépasse la marche incompressible que la lampe injecte dès 1%.
            let ignitionThreshold = max(turnOnHysteresis, minStepLuma * 0.85)
            
            if autoPowerToggle && error >= ignitionThreshold {
                excessLightCycleCount = 0
                DispatchQueue.main.async {
                    self.statusMessage = L10n.autoWakeMsg
                }
                // Amorce douce au palier minimal physique (1%)
                applyLampPower?(true)
                applyLampBrightness?(1.0)
            } else {
                DispatchQueue.main.async {
                    self.statusMessage = L10n.standbySufficient
                }
            }
            return
        }
        
        // -------------------------------------------------------------
        // CAS 2 : La lampe est ALLUMÉE
        // -------------------------------------------------------------
        
        // Extinction automatique si les autres sources suffisent seules (error <= 0%)
        // et que la lampe a déjà été tamisée jusqu'à son plancher (<= 1.5%)
        if autoPowerToggle && error <= 0.0 && currentLamp <= 1.5 {
            excessLightCycleCount += 1
            if excessLightCycleCount >= excessCyclesRequired {
                excessLightCycleCount = 0
                DispatchQueue.main.async {
                    self.statusMessage = L10n.autoSleepMsg
                }
                applyLampPower?(false)
                return
            }
        } else {
            excessLightCycleCount = 0
        }
        
        // 1. Zone morte dynamique proportionnelle au plancher minimal
        let dynamicDeadband = max(deadband, minStepLuma * 0.25)
        if abs(error) < dynamicDeadband {
            DispatchQueue.main.async {
                self.statusMessage = L10n.stableAmbiance
            }
            return
        }
        
        // 2. Correction proportionnelle LBNL amortie : ΔB = (η / G) * error
        // avec facteur d'amortissement critique η = 0.60
        let dampingFactor = 0.60
        let safeGain = max(0.08, couplingAlpha)
        let desiredDelta = (dampingFactor / safeGain) * error
        
        // 3. Limitation de rampe douce : 2% max par cycle (1.8s)
        let step = max(-maxStepPerCycle, min(maxStepPerCycle, desiredDelta))
        let nextBrightness = max(1.0, min(100.0, currentLamp + step))
        
        DispatchQueue.main.async {
            self.statusMessage = (step > 0) ? L10n.compensatingPlus : L10n.compensatingMinus
        }
        
        // 4. Application au variateur
        applyLampBrightness?(nextBrightness)
    }
}
