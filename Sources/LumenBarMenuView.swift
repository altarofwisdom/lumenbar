import SwiftUI

struct LumenBarMenuView: View {
    @ObservedObject var lamp: LampController
    @State private var manualUUIDInput: String = ""
    @State private var showManualInput: Bool = false
    
    var body: some View {
        VStack(spacing: 12) {
            if lamp.configuredAddress == nil || lamp.showDeviceManager {
                // MARK: - Vue Gestion des Dispositifs & Découverte
                deviceManagerView
            } else {
                // MARK: - Vue Principale de Contrôle
                controlsView
            }
        }
        .padding(14)
        .frame(width: 330)
    }
    
    // MARK: - Vue Principale : Contrôles de la Lampe
    private var controlsView: some View {
        VStack(spacing: 12) {
            // En-tête : Nom, État, Réglages et Interrupteur Général
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(lamp.isOn ? Color.yellow.opacity(0.2) : Color.gray.opacity(0.15))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: lamp.statusIcon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(lamp.isOn ? .yellow : .secondary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("LumenBar")
                        .font(.system(size: 13, weight: .bold))
                    
                    HStack(spacing: 5) {
                        Circle()
                            .fill(lamp.isConnected ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(lamp.statusText)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Bouton Paramètres / Dispositif
                Button(action: {
                    lamp.showDeviceManager = true
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Gérer ou oublier le luminaire")
                
                // Bouton Power Principal
                Button(action: {
                    lamp.togglePower()
                }) {
                    Image(systemName: "power.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(lamp.isOn ? .green : .secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help(lamp.isOn ? "Éteindre le luminaire" : "Allumer le luminaire")
            }
            .padding(.bottom, 2)
            
            Divider()
            
            // Variateur Luminosité
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Luminosité", systemImage: "sun.max.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(Int(lamp.brightness)) %")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 8) {
                    Image(systemName: "sun.min")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    Slider(
                        value: Binding(
                            get: { lamp.brightness },
                            set: { lamp.userSetBrightness($0, immediate: false) }
                        ),
                        in: 1...100,
                        onEditingChanged: { editing in
                            if !editing {
                                lamp.userSetBrightness(lamp.brightness, immediate: true)
                            }
                        }
                    )
                    
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.yellow)
                }
                
                HStack(spacing: 6) {
                    ForEach([25, 50, 75, 100], id: \.self) { val in
                        Button("\(val)%") {
                            lamp.userSetBrightness(Double(val), immediate: true)
                        }
                        .buttonStyle(PresetPillStyle(isSelected: Int(round(lamp.brightness)) == val))
                    }
                }
            }
            
            Divider()
            
            // MARK: - AutoLight (Webcam)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("AutoLight (Webcam)", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(lamp.autoLight.isEnabled ? .yellow : .primary)
                    
                    Spacer()
                    
                    Toggle("", isOn: $lamp.autoLight.isEnabled)
                        .toggleStyle(.switch)
                        .scaleEffect(0.8)
                        .labelsHidden()
                }
                
                if lamp.autoLight.isEnabled {
                    VStack(spacing: 6) {
                        HStack {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(lamp.autoLight.isCalibrating ? Color.orange : Color.green)
                                    .frame(width: 6, height: 6)
                                Text(lamp.autoLight.statusMessage)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: {
                                lamp.autoLight.calibrateCoupling()
                            }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "slider.horizontal.below.rectangle")
                                    Text("Étalonner")
                                }
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .disabled(lamp.autoLight.isCalibrating)
                            .help("Mesure le couplage optique entre la lampe et la webcam pour éviter les boucles")
                        }
                        
                        // Jauge de lumière ambiante externe estimée
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Lumière ambiante détectée")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(round(lamp.autoLight.estimatedExternalLux))) %")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            ProgressView(value: lamp.autoLight.estimatedExternalLux, total: 100)
                                .progressViewStyle(LinearProgressViewStyle(tint: .yellow.opacity(0.8)))
                                .scaleEffect(x: 1, y: 0.5, anchor: .center)
                        }
                        
                        // Curseur de confort souhaité
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Ambiance souhaitée")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(round(lamp.autoLight.targetComfort))) %")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $lamp.autoLight.targetComfort, in: 20...100)
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(6)
                }
            }
            
            Divider()
            
            // Température Blanc CCT (2700K - 6500K)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Blanc CCT", systemImage: "thermometer.sun.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(Int(lamp.temperature)) K (\(lamp.temperatureLabel))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                Slider(
                    value: Binding(
                        get: { lamp.temperature },
                        set: { lamp.setTemperature($0, immediate: false) }
                    ),
                    in: 2700...6500,
                    onEditingChanged: { editing in
                        if !editing {
                            lamp.setTemperature(lamp.temperature, immediate: true)
                        }
                    }
                )
                
                HStack(spacing: 6) {
                    Button("Chaud 2700K") {
                        lamp.setTemperature(2700, immediate: true)
                    }
                    .buttonStyle(PresetPillStyle(isSelected: Int(round(lamp.temperature)) <= 3100))
                    
                    Button("Neutre 4000K") {
                        lamp.setTemperature(4000, immediate: true)
                    }
                    .buttonStyle(PresetPillStyle(isSelected: Int(round(lamp.temperature)) > 3100 && Int(round(lamp.temperature)) < 5500))
                    
                    Button("Froid 6500K") {
                        lamp.setTemperature(6500, immediate: true)
                    }
                    .buttonStyle(PresetPillStyle(isSelected: Int(round(lamp.temperature)) >= 5500))
                }
            }
            
            Divider()
            
            // Couleurs & Roue Chromatique
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Couleur & Teinte", systemImage: "paintpalette.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(Int(lamp.hue))°")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 8) {
                    ForEach(lamp.presets) { p in
                        Button(action: {
                            lamp.setColor(preset: p)
                        }) {
                            Circle()
                                .fill(Color(red: p.r, green: p.g, blue: p.b))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary.opacity(0.3), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(p.name)
                    }
                }
                
                Slider(
                    value: Binding(
                        get: { lamp.hue },
                        set: { lamp.setHue($0, immediate: false) }
                    ),
                    in: 0...360,
                    onEditingChanged: { editing in
                        if !editing {
                            lamp.setHue(lamp.hue, immediate: true)
                        }
                    }
                )
            }
            
            Divider()
            
            // Pied de Menu : Actualiser & Quitter
            HStack {
                Button(action: {
                    lamp.fetchStatus()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Actualiser")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button(action: {
                    lamp.quitApp()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text("Quitter LumenBar")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Éteint la lampe et quitte l'application")
            }
            .padding(.top, 2)
        }
    }
    
    // MARK: - Vue Gestion des Dispositifs : Découverte & Oubli
    private var deviceManagerView: some View {
        VStack(spacing: 12) {
            // En-tête de la gestion
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
                
                Text(lamp.configuredAddress == nil ? "Association du Luminaire" : "Gestion du Dispositif")
                    .font(.system(size: 13, weight: .bold))
                
                Spacer()
                
                if lamp.configuredAddress != nil {
                    Button(action: {
                        lamp.showDeviceManager = false
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                            Text("Retour")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Divider()
            
            // Si un dispositif est actuellement configuré
            if let addr = lamp.configuredAddress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Luminaire associé")
                                .font(.system(size: 11, weight: .semibold))
                            Text(addr)
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(lamp.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(6)
                    
                    // Bouton Oublier ce luminaire
                    Button(action: {
                        lamp.forgetDevice()
                    }) {
                        HStack {
                            Spacer()
                            Image(systemName: "trash")
                            Text("Oublier ce luminaire")
                            Spacer()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                
                Divider()
            } else {
                VStack(spacing: 4) {
                    Text("Aucun luminaire configuré")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.orange)
                    Text("Lancez une recherche Bluetooth pour détecter et associer votre luminaire.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 4)
            }
            
            // Section Recherche Bluetooth
            VStack(spacing: 8) {
                HStack {
                    Text("Luminaires à proximité")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    
                    if lamp.isScanning {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Button(action: {
                            lamp.scanForDevices()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "magnifyingglass")
                                Text("Rechercher")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                if let msg = lamp.scanMessage {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // Liste des dispositifs trouvés
                if !lamp.discoveredDevices.isEmpty {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(lamp.discoveredDevices) { dev in
                                HStack {
                                    Image(systemName: dev.isCompatible ? "lightbulb.fill" : "wave.3.left")
                                        .font(.system(size: 14))
                                        .foregroundColor(dev.isCompatible ? .yellow : .secondary)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(dev.name)
                                                .font(.system(size: 11, weight: .semibold))
                                            
                                            if dev.isCompatible {
                                                Text("Inspire")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(Color.green.opacity(0.2))
                                                    .foregroundColor(.green)
                                                    .cornerRadius(3)
                                            }
                                        }
                                        
                                        Text("\(dev.address) • \(dev.rssi) dBm")
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Button("Associer") {
                                        lamp.pairDevice(address: dev.address)
                                    }
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor)
                                    .foregroundColor(.white)
                                    .cornerRadius(5)
                                    .buttonStyle(.plain)
                                }
                                .padding(6)
                                .background(Color.primary.opacity(0.04))
                                .cornerRadius(6)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
            
            Divider()
            
            // Saisie manuelle d'UUID (Optionnelle)
            VStack(alignment: .leading, spacing: 5) {
                Button(action: {
                    showManualInput.toggle()
                }) {
                    HStack {
                        Text("Saisie manuelle d'une adresse UUID")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Image(systemName: showManualInput ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                if showManualInput {
                    HStack(spacing: 6) {
                        TextField("UUID (ex: 9F17ABB9-...)", text: $manualUUIDInput)
                            .font(.system(size: 9, design: .monospaced))
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        Button("Valider") {
                            lamp.pairDevice(address: manualUUIDInput)
                            manualUUIDInput = ""
                        }
                        .font(.system(size: 10, weight: .medium))
                        .disabled(manualUUIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            
            Divider()
            
            // Pied : Quitter
            HStack {
                Spacer()
                Button(action: {
                    lamp.quitApp()
                }) {
                    Text("Quitter LumenBar")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Style pour les boutons capsules
struct PresetPillStyle: ButtonStyle {
    var isSelected: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: isSelected ? .bold : .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .allowsTightening(true)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
