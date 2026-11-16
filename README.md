# LumenBar

> **Contrôleur Bluetooth Low Energy (BLE) direct et application macOS Menu Bar pour luminaires connectés (Inspire / Lexman / GATT).**

[![macOS](https://img.shields.io/badge/macOS-13.0+-black.svg?style=flat&logo=apple)](https://apple.com)
[![Swift](https://img.shields.io/badge/Swift-5.9+-F05138.svg?style=flat&logo=swift)](https://swift.org)
[![Python](https://img.shields.io/badge/Python-3.10+-3776AB.svg?style=flat&logo=python)](https://python.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

LumenBar permet de piloter instantanément et localement en direct (sans pont Zigbee, sans passerelle Cloud, sans hub externe) les luminaires connectés commercialisés sous les marques **Inspire** et **Lexman** (groupe Adeo / Leroy Merlin, notamment le plafonnier LED *Inspire Gdansk* `ZBEK-27`) ainsi que tout équipement exploitant le service GATT propriétaire `0000a101-1115-1000-0001-617573746f6d`.

---

## Fonctionnalités

* 🚀 **Latence ultra-faible (< 30 ms)** : Démon Python d'arrière-plan maintenant une liaison BLE CoreBluetooth persistante et communiquant par socket UNIX avec l'interface.
* 🖥️ **Application macOS Menu Bar native** : Développée en Swift & SwiftUI (`LSUIElement`), discrète dans la barre des menus, sans fenêtre flottante superflue.
* 💡 **Gradateur & Allumage** : Contrôle continu de luminosité de 1% à 100% avec boutons de présélection instantanée (25%, 50%, 75%, 100%).
* 👁️ **AutoLight par Webcam avec Découplage de Rétroaction** : Régulation adaptative selon la lumière ambiante naturelle, immunisée contre les boucles de rétroaction optique (Feed-Forward Cancellation $L_{\text{ext}} = L_{\text{mesuré}} - \alpha \cdot B$, étalonnage automatique de $\alpha$, bande morte $\pm 4\%$ et limitation de rampe $2.5\%$/s).
* 🌡️ **Blanc variable CCT (2700K - 6500K)** : Régulation continue de la température de couleur (Chaud, Neutre, Froid).
* 🎨 **Roue Chromatique 360°** : Prise en charge de la sélection de teinte exacte ou via palette de nuances directes.
* 🔍 **Découverte & Appairage intégrés** : Scanner Bluetooth intégré dans l'application pour détecter, associer ou oublier un luminaire en un clic.
* 🔌 **Arrêt propre & Éco-énergie** : Extinction automatique de l'éclairage et fermeture propre de la session BLE à la fermeture de l'application.

---

## Architecture

```
┌────────────────────────────────────────────────────────┐
│      LumenBar.app (SwiftUI & AppKit MenuBarExtra)      │
│      • Interface popover barre des menus               │
│      • Gestion de la découverte BLE et appairage       │
│      • Sliders & sélecteurs d'état                     │
└───────────────────────────┬────────────────────────────┘
                            │ Socket UNIX (/tmp/lumenbar.sock)
                            ▼
┌────────────────────────────────────────────────────────┐
│      Démon Python BLE (`lumenbar.py _daemon_worker`)   │
│      • Maintient la connexion CoreBluetooth (Bleak)    │
│      • Traite les requêtes asynchrones en continu      │
│      • Reçoit et décode les notifications de la lampe  │
└───────────────────────────┬────────────────────────────┘
                            │ Bluetooth LE GATT
                            ▼
┌────────────────────────────────────────────────────────┐
│      Luminaire Connecté (Inspire / Lexman / ZBEK-27)   │
└────────────────────────────────────────────────────────┘
```

---

## Régulation Adaptative AutoLight (Anti-Rétroaction)

Quand une webcam pointe vers un bureau éclairé par la lampe, tout assombrissement externe induit une hausse de la lampe, laquelle renvoie du flux vers la caméra. Sans précaution, ce couplage engendre un pompage oscillatoire permanent ou une lutte avec l'exposition automatique (AEC) de la caméra.

LumenBar résout ce problème avec une boucle de contrôle découplée :
1. **Échantillonnage passif & confidentiel** : Prélèvement discret (1 trame toutes les 1.8s) via `AVFoundation` sous forme de matrice réduite en RAM (aucune vidéo ni photo n'est enregistrée).
2. **Découplage Feed-Forward** : Soustraction de la contribution propre de la lampe :
   $$L_{\text{externe}} = \max(0, L_{\text{mesuré}} - \alpha \cdot B_{\text{lampe}})$$
3. **Auto-Étalonnage du coefficient $\alpha$** : Mesure in-situ du couplage optique par échelon test pour déduire le facteur $\alpha$ spécifique à la géométrie de la pièce.
4. **Filtre passe-bas (EMA) & Bande morte ($\pm 4\%$)** : Les ombres fugaces (passage d'une main, mouvement de tête) sont filtrées.
5. **Limitation de rampe douce** : Variation bornée à $\le 2.5\%$ par cycle, garantissant des transitions visuelles fluides et reposantes pour les yeux.

---

## Protocole GATT & Trames Hexadécimales

* **UUID d'écriture (Write with response)** : `0000a101-1115-1000-0001-617573746f6d`
* **UUID de lecture / notifications** : `0000a102-1115-1000-0001-617573746f6d`

### Format des Trames de Commande

Chaque trame commence par le préfixe `00 00` suivi de l'identifiant de fonction (opcode), de la longueur utile et de la valeur :

| Fonction | Opcode | Trame Hexadécimale | Plage / Description |
| :--- | :---: | :--- | :--- |
| **Allumage (ON)** | `0x10` | `0000100103010000` | Allume le luminaire |
| **Extinction (OFF)**| `0x10` | `0000100103000000` | Éteint le luminaire |
| **Luminosité (Dim)**| `0x11` | `0000110103[VAL]0000` | `[VAL]` de `0x00` (0%) à `0xFE` (100%) |
| **Blanc CCT** | `0x12` | `0000120104[B1][B0]0000` | Valeur 16-bit Mireds (`0x0099` = 6500K à `0x01C6` = 2700K) |
| **Teinte (Hue)** | `0x13` | `0000130103[VAL]0000` | Angle 0°–360° proportionnel sur `0x00` à `0xFE` |

### Interrogation d'État
* `00001002` : Lecture de l'état d'alimentation
* `00001102` : Lecture du niveau de luminosité
* `00001202` : Lecture de la température CCT
* `00001302` : Lecture de la teinte de couleur

---

## Utilisation en Ligne de Commande (CLI)

Le script Python [Resources/lumenbar.py](file:///Users/yoto/LumenBar/Resources/lumenbar.py) peut être utilisé directement :

```bash
# Rechercher les luminaires compatibles
python3 Resources/lumenbar.py scan

# Allumer / Éteindre
python3 Resources/lumenbar.py on
python3 Resources/lumenbar.py off

# Régler la luminosité (0 à 100 %)
python3 Resources/lumenbar.py dim 60

# Régler la température de blanc (2700 à 6500 K)
python3 Resources/lumenbar.py temp 4000

# Régler la couleur (nom ou degré 0-360)
python3 Resources/lumenbar.py color blue
python3 Resources/lumenbar.py hue 210

# Consulter l'état complet
python3 Resources/lumenbar.py status
```

---

## Compilation & Installation de l'Application macOS

L'application ne requiert pas Xcode complet : les Command Line Tools (`swiftc`) suffisent :

```bash
./build.sh
```

Le script produit et signe localement l'application dans `~/Applications/LumenBar.app`.

---

## Licence

Projet open source publié sous licence [MIT](LICENSE).
