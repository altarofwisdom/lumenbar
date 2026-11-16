import Foundation
import Combine

/// Langue de l'interface
enum AppLanguage: String, CaseIterable, Identifiable {
    case auto = "auto"
    case en = "en"
    case fr = "fr"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .auto:
            return L10n.isFrenchSystem ? "Automatique (Français)" : "Automatic (English)"
        case .en:
            return "English"
        case .fr:
            return "Français"
        }
    }
}

/// Gestionnaire de localisation dynamique avec détection automatique de la langue système
class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    
    @Published var selectedLanguage: AppLanguage = .auto {
        didSet {
            saveLanguagePreference(selectedLanguage)
        }
    }
    
    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lumenbar_config.json")
    }
    
    init() {
        self.selectedLanguage = loadSavedLanguage()
    }
    
    var isFrench: Bool {
        switch selectedLanguage {
        case .auto:
            return L10n.isFrenchSystem
        case .en:
            return false
        case .fr:
            return true
        }
    }
    
    private func loadSavedLanguage() -> AppLanguage {
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let langStr = json["language"] as? String,
           let lang = AppLanguage(rawValue: langStr) {
            return lang
        }
        return .auto
    }
    
    private func saveLanguagePreference(_ lang: AppLanguage) {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = json
        }
        dict["language"] = lang.rawValue
        if let updated = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? updated.write(to: configURL)
        }
    }
}

/// Dictionnaire des chaînes localisées
struct L10n {
    static var isFrenchSystem: Bool {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("fr")
    }
    
    static var isFrench: Bool {
        LocalizationManager.shared.isFrench
    }
    
    // MARK: - En-tête & États
    static var appTitle: String { "LumenBar" }
    static var connected: String { isFrench ? "Connecté" : "Connected" }
    static var connecting: String { isFrench ? "Connexion..." : "Connecting..." }
    static var notConfigured: String { isFrench ? "Non configuré" : "Not configured" }
    static var startingDaemon: String { isFrench ? "Démarrage du démon..." : "Starting daemon..." }
    static var reconnecting: String { isFrench ? "Reconnexion..." : "Reconnecting..." }
    static var outOfRange: String { isFrench ? "Lampe hors de portée ou occupée" : "Lamp out of range or busy" }
    
    // MARK: - Contrôles & Variateurs
    static var brightness: String { isFrench ? "Luminosité" : "Brightness" }
    static var cctWhite: String { isFrench ? "Blanc CCT" : "CCT White" }
    static var warm: String { isFrench ? "Chaud" : "Warm" }
    static var neutral: String { isFrench ? "Neutre" : "Neutral" }
    static var cold: String { isFrench ? "Froid" : "Cool" }
    static var warmPreset: String { isFrench ? "Chaud 2700K" : "Warm 2700K" }
    static var neutralPreset: String { isFrench ? "Neutre 4000K" : "Neutral 4000K" }
    static var coldPreset: String { isFrench ? "Froid 6500K" : "Cool 6500K" }
    static var colorHue: String { isFrench ? "Couleur & Teinte" : "Color & Hue" }
    static var refresh: String { isFrench ? "Actualiser" : "Refresh" }
    static var quitApp: String { isFrench ? "Quitter LumenBar" : "Quit LumenBar" }
    static var quitHelp: String { isFrench ? "Éteint la lampe et quitte l'application" : "Turns off lamp and quits app" }
    static var manageHelp: String { isFrench ? "Gérer ou oublier le luminaire" : "Manage or forget luminaire" }
    static var turnOffHelp: String { isFrench ? "Éteindre le luminaire" : "Turn off luminaire" }
    static var turnOnHelp: String { isFrench ? "Allumer le luminaire" : "Turn on luminaire" }
    
    // MARK: - AutoLight
    static var autoLightTitle: String { "AutoLight (Webcam)" }
    static var webcamSource: String { isFrench ? "Webcam" : "Webcam" }
    static var noWebcam: String { isFrench ? "Aucune webcam" : "No webcam" }
    static var virtualTag: String { isFrench ? "Virtuelle" : "Virtual" }
    static var calibrate: String { isFrench ? "Étalonner" : "Calibrate" }
    static var measuring: String { isFrench ? "Mesure..." : "Measuring..." }
    static var calibrating: String { isFrench ? "Étalonnage en cours..." : "Calibrating..." }
    static var calibratingLock: String { isFrench ? "Étalonnage : verrouillage expo..." : "Calibrating: locking exposure..." }
    static var calibratingOff: String { isFrench ? "Étalonnage : ambiance (lampe éteinte)..." : "Calibrating: ambient (lamp off)..." }
    static var calibratingMin: String { isFrench ? "Étalonnage : seuil min (lampe à 1%)..." : "Calibrating: min step (lamp at 1%)..." }
    static var calibratingOn: String { isFrench ? "Étalonnage : réponse (lampe à 80%)..." : "Calibrating: response (lamp at 80%)..." }
    static var calibrateHelp: String { isFrench ? "Verrouille l'exposition et mesure le seuil 1% et le gain optique du luminaire (norme Lutron/LBNL)" : "Locks exposure and measures 1% threshold and optical gain (Lutron/LBNL standard)" }
    static func calibrated(alpha: Double, minStep: Double = 0.0) -> String {
        if minStep > 0.0 {
            return isFrench ? String(format: "Étalonné (G = %.2f, Min = +%.1f%%)", alpha, minStep) : String(format: "Calibrated (G = %.2f, Min = +%.1f%%)", alpha, minStep)
        }
        return isFrench ? String(format: "Étalonné (G = %.2f)", alpha) : String(format: "Calibrated (G = %.2f)", alpha)
    }
    static var ambientDetected: String { isFrench ? "Lumière mesurée" : "Measured light" }
    static var targetComfort: String { isFrench ? "Ambiance souhaitée" : "Target comfort" }
    static var autoPowerToggle: String { isFrench ? "Éteindre/rallumer auto" : "Auto sleep & wake" }
    static var autoPowerHelp: String { isFrench ? "Éteint automatiquement la lampe si la lumière du jour suffit, et la rallume dès que la pièce s'assombrit" : "Automatically turns off the lamp when daylight suffices, and wakes it when room gets darker" }
    static var autoLightActive: String { isFrench ? "AutoLight actif" : "AutoLight active" }
    static var autoLightInactive: String { isFrench ? "AutoLight inactif" : "AutoLight inactive" }
    static var stableAmbiance: String { isFrench ? "Ambiance stable" : "Lighting stable" }
    static var compensatingPlus: String { isFrench ? "Compensation (+)..." : "Compensating (+)..." }
    static var compensatingMinus: String { isFrench ? "Compensation (-)..." : "Compensating (-)..." }
    static var autoWakeMsg: String { isFrench ? "Allumage doux..." : "Soft wake-up..." }
    static var autoSleepMsg: String { isFrench ? "Extinction auto (lumière suffisante)" : "Auto sleep (sufficient light)" }
    static var standbySufficient: String { isFrench ? "Veille (Lumière naturelle suffisante)" : "Standby (Sufficient daylight)" }
    static var manuallyOffPause: String { isFrench ? "Éteint manuellement (pause)" : "Manually off (paused)" }
    static var cameraPermissionDenied: String { isFrench ? "Accès caméra refusé" : "Camera access denied" }
    static var cameraNotAuthorized: String { isFrench ? "Accès caméra non autorisé" : "Camera not authorized" }
    static var noWebcamDetected: String { isFrench ? "Aucune webcam détectée" : "No webcam detected" }
    static func cameraSelected(name: String) -> String {
        return isFrench ? "Caméra : \(name)" : "Camera: \(name)"
    }
    
    // MARK: - Gestion des Dispositifs
    static var deviceManagement: String { isFrench ? "Gestion du Dispositif" : "Device Management" }
    static var pairLuminaire: String { isFrench ? "Association du Luminaire" : "Pair Luminaire" }
    static var back: String { isFrench ? "Retour" : "Back" }
    static var pairedLuminaire: String { isFrench ? "Luminaire associé" : "Paired Luminaire" }
    static var forgetLuminaire: String { isFrench ? "Oublier ce luminaire" : "Forget this luminaire" }
    static var noLuminaireConfigured: String { isFrench ? "Aucun luminaire configuré" : "No luminaire configured" }
    static var scanToPairPrompt: String { isFrench ? "Lancez une recherche Bluetooth pour détecter et associer votre luminaire." : "Start a Bluetooth scan to discover and pair your luminaire." }
    static var nearbyLuminaires: String { isFrench ? "Luminaires à proximité" : "Nearby Luminaires" }
    static var scanBtn: String { isFrench ? "Rechercher" : "Scan" }
    static var scanningMsg: String { isFrench ? "Recherche Bluetooth en cours (6s)..." : "Scanning Bluetooth (6s)..." }
    static func devicesFound(count: Int) -> String {
        return isFrench ? "\(count) équipement(s) trouvé(s)" : "\(count) device(s) found"
    }
    static var noDevicesFound: String { isFrench ? "Aucun luminaire détecté. Vérifiez que la lampe est sous tension et déconnectée du smartphone." : "No luminaire found. Ensure lamp is powered on and disconnected from smartphone." }
    static var pairBtn: String { isFrench ? "Associer" : "Pair" }
    static var manualUUIDEntry: String { isFrench ? "Saisie manuelle d'une adresse UUID" : "Manual UUID entry" }
    static var validateBtn: String { isFrench ? "Valider" : "Apply" }
    static var languageLabel: String { isFrench ? "Langue" : "Language" }
    static var unknown: String { isFrench ? "Inconnu" : "Unknown" }
    
    // MARK: - Couleurs Prédéfinies
    static func colorName(_ key: String) -> String {
        switch key.lowercased() {
        case "rouge", "red": return isFrench ? "Rouge" : "Red"
        case "orange": return "Orange"
        case "jaune", "yellow": return isFrench ? "Jaune" : "Yellow"
        case "vert", "green": return isFrench ? "Vert" : "Green"
        case "cyan": return "Cyan"
        case "bleu", "blue": return isFrench ? "Bleu" : "Blue"
        case "violet", "purple": return isFrench ? "Violet" : "Purple"
        case "rose", "pink": return isFrench ? "Rose" : "Pink"
        default: return key
        }
    }
}
