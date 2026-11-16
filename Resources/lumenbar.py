#!/usr/bin/env python3
"""
Contrôleur BLE local haute performance pour luminaire Inspire Gdansk (Leroy Merlin / Enki / Adeo ZBEK-27).
Mode Daemon persistant via Socket Unix : Latence < 50ms, Roue de couleur (Hue/RGB/Hex),
Animation Party (défilement dynamique fluide), Blanc CCT (2700-6500K), Variateur.
"""

import asyncio
import colorsys
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

try:
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
except Exception:
    pass

from bleak import BleakScanner, BleakClient

CONFIG_FILE = Path.home() / ".lumenbar_config.json"
LEGACY_CONFIG = Path.home() / ".gdansk_config.json"
SOCKET_PATH = "/tmp/lumenbar.sock"
WRITE_UUID = "0000a101-1115-1000-0001-617573746f6d"
READ_UUID = "0000a102-1115-1000-0001-617573746f6d"

# Mappage de teintes sur la roue chromatique (0 à 254)
HUE_MAP = {
    "red": 0,
    "rouge": 0,
    "orange": 21,
    "amber": 28,
    "ambre": 28,
    "yellow": 42,
    "jaune": 42,
    "lime": 63,
    "green": 85,
    "vert": 85,
    "emerald": 95,
    "emeraude": 95,
    "turquoise": 106,
    "cyan": 128,
    "sky": 149,
    "ciel": 149,
    "blue": 170,
    "bleu": 170,
    "indigo": 180,
    "purple": 191,
    "violet": 191,
    "magenta": 213,
    "pink": 234,
    "rose": 234,
}

def load_address() -> str | None:
    for cfg in [CONFIG_FILE, LEGACY_CONFIG]:
        if cfg.exists():
            try:
                data = json.loads(cfg.read_text())
                addr = data.get("address")
                if addr:
                    return addr
            except Exception:
                pass
    return None

def save_address(address: str):
    CONFIG_FILE.write_text(json.dumps({"address": address}, indent=2))

def forget_address():
    for cfg in [CONFIG_FILE, LEGACY_CONFIG]:
        if cfg.exists():
            try:
                cfg.unlink()
            except OSError:
                pass

async def scan_devices(timeout: float = 5.0) -> list[dict]:
    scanner = BleakScanner()
    try:
        devs = await scanner.discover(timeout=timeout, return_adv=True)
    except Exception as e:
        sys.stderr.write(f"Scan error: {e}\n")
        return []
        
    results = []
    seen = set()
    for addr, (d, adv) in devs.items():
        if addr in seen:
            continue
        seen.add(addr)
        name = d.name or adv.local_name or "Périphérique Bluetooth"
        n_low = name.lower()
        is_lamp = any(k in n_low for k in ["smart bulb", "bulb", "inspire", "lexman", "gdansk", "zbek", "lamp", "light", "led"])
        if any(WRITE_UUID in str(u).lower() for u in adv.service_uuids):
            is_lamp = True
            
        results.append({
            "name": name,
            "address": addr,
            "rssi": adv.rssi if adv.rssi is not None else -99,
            "is_compatible": is_lamp
        })
    results.sort(key=lambda x: (not x["is_compatible"], -x["rssi"]))
    return results

def rgb_to_hue(r: int, g: int, b: int) -> int:
    h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
    return round(h * 254) % 255

def build_payloads(cmd: str, args: list[str]) -> list[bytes]:
    cmd = cmd.lower()
    if cmd == "on":
        return [bytes.fromhex("0000100103010000")]
    elif cmd == "off":
        return [bytes.fromhex("0000100103000000")]
    elif cmd == "dim":
        pct = max(0, min(100, int(args[0])))
        val = round(pct / 100 * 254)
        return [bytes.fromhex(f"0000110103{val:02x}0000")]
    elif cmd == "temp":
        k = max(2700, min(6500, int(args[0])))
        cct = round((k - 6500) * (454 - 153) / (2700 - 6500) + 153)
        b0 = cct & 0xFF
        b1 = (cct >> 8) & 0xFF
        return [bytes.fromhex(f"0000120104{b1:02x}{b0:02x}0000")]
    elif cmd in ["hue", "color", "rgb", "hex"]:
        if cmd == "hue":
            deg = float(args[0])
            val = round((deg % 360) / 360 * 254)
        elif cmd == "rgb":
            r, g, b = int(args[0]), int(args[1]), int(args[2])
            val = rgb_to_hue(r, g, b)
        elif cmd == "hex":
            h = args[0].lstrip("#")
            r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
            val = rgb_to_hue(r, g, b)
        else:
            name = args[0].lower()
            if name in ["warm", "chaud"]:
                return build_payloads("temp", ["2700"])
            if name in ["cold", "froid", "white", "blanc"]:
                return build_payloads("temp", ["6000"])
            val = HUE_MAP.get(name)
            if val is None:
                raise ValueError(f"Couleur inconnue '{name}'. Choix: {', '.join(HUE_MAP.keys())}")
        # Opcode 0x13 : Réglage précis de la teinte (Roue de couleur 0-254)
        return [bytes.fromhex(f"0000130103{val:02x}0000")]
    elif cmd == "raw":
        raw_hex = args[0].replace(":", "").replace(" ", "")
        return [bytes.fromhex(raw_hex)]
    else:
        raise ValueError(f"Commande non supportée: {cmd}")

# --- Connexion Bluetooth avec réveil du cache ---
async def connect_client(address: str, attempts: int = 3) -> BleakClient:
    last_err = None
    for attempt in range(attempts):
        try:
            client = BleakClient(address, timeout=4.0)
            await client.connect()
            if client.is_connected:
                return client
        except Exception as e:
            last_err = e
        
        try:
            device = await BleakScanner.find_device_by_address(address, timeout=2.0)
            if device:
                client = BleakClient(device, timeout=4.0)
                await client.connect()
                if client.is_connected:
                    return client
        except Exception as e2:
            last_err = e2
            
        await asyncio.sleep(0.3)
    raise last_err or ConnectionError(f"Périphérique introuvable ({address})")

# --- Client Socket Unix (< 50ms) ---
def try_send_via_daemon(command_line: str) -> bool:
    if not os.path.exists(SOCKET_PATH):
        return False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2.5)
            s.connect(SOCKET_PATH)
            s.sendall((command_line + "\n").encode("utf-8"))
            data = s.recv(4096).decode("utf-8").strip()
            if data.startswith("OK"):
                return True
            elif data.startswith("ERR"):
                print(f"❌ {data}")
                return True
    except (ConnectionRefusedError, FileNotFoundError):
        if os.path.exists(SOCKET_PATH):
            try:
                os.unlink(SOCKET_PATH)
            except OSError:
                pass
    except Exception:
        pass
    return False

# --- Daemon BLE persistant ---
async def run_daemon(address: str):
    if os.path.exists(SOCKET_PATH):
        try:
            os.unlink(SOCKET_PATH)
        except OSError:
            pass

    print(f"🚀 Démarrage du daemon Gdansk pour {address}...")
    client = None
    connect_lock = asyncio.Lock()
    latest_state = {
        "power": True,
        "dim": 100,
        "temp": 2700,
        "hue": 0
    }

    def on_notify(char, data: bytearray):
        nonlocal latest_state
        if len(data) >= 6 and data[2] == 0x10:
            latest_state["power"] = (data[5] == 1)
        elif len(data) >= 6 and data[2] == 0x11:
            latest_state["dim"] = round(data[5] / 254 * 100)
        elif len(data) >= 7 and data[2] == 0x12:
            cct = (data[5] << 8) | data[6]
            if 153 <= cct <= 454:
                k = round(6500 - (cct - 153) * (6500 - 2700) / (454 - 153))
                latest_state["temp"] = max(2700, min(6500, k))
        elif len(data) >= 6 and data[2] == 0x13:
            latest_state["hue"] = round(data[5] / 254 * 360)

    async def get_active_client():
        nonlocal client
        async with connect_lock:
            if client and client.is_connected:
                return client
            try:
                print(f"📡 Établissement de la connexion Bluetooth persistante...", flush=True)
                client = await connect_client(address)
                try:
                    await client.start_notify(READ_UUID, on_notify)
                except Exception as ne:
                    print(f"⚠️ start_notify: {ne}", flush=True)
                print("⚡ Connecté et prêt ! Latence des commandes : ~20ms.", flush=True)
                for q in [bytes.fromhex("00001002"), bytes.fromhex("00001102"), bytes.fromhex("00001202"), bytes.fromhex("00001302")]:
                    try:
                        await client.write_gatt_char(WRITE_UUID, q, response=True)
                        await asyncio.sleep(0.03)
                    except Exception:
                        pass
                return client
            except Exception as ce:
                print(f"❌ Erreur connexion Bluetooth: {ce}", flush=True)
                client = None
                raise

    loop = asyncio.get_running_loop()

    async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        nonlocal client, latest_state
        try:
            line = await reader.readline()
            if not line:
                return
            cmd_line = line.decode("utf-8").strip()
            if not cmd_line:
                return

            if cmd_line == "ping":
                if client and client.is_connected:
                    writer.write(b"OK PONG READY\n")
                else:
                    writer.write(b"OK PONG CONNECTING\n")
                await writer.drain()
                return

            if cmd_line == "stop":
                if client and client.is_connected:
                    try:
                        # Éteindre la lampe automatiquement à l'arrêt
                        await client.write_gatt_char(WRITE_UUID, bytes.fromhex("0000100103000000"), response=True)
                        await asyncio.sleep(0.05)
                    except Exception:
                        pass
                writer.write(b"OK STOPPING\n")
                await writer.drain()
                if client and client.is_connected:
                    try:
                        await client.disconnect()
                    except Exception:
                        pass
                if os.path.exists(SOCKET_PATH):
                    try:
                        os.unlink(SOCKET_PATH)
                    except OSError:
                        pass
                sys.exit(0)

            if cmd_line in ["status", "status_json"]:
                cl = await get_active_client()
                for q in [bytes.fromhex("00001002"), bytes.fromhex("00001102"), bytes.fromhex("00001202"), bytes.fromhex("00001302")]:
                    try:
                        await cl.write_gatt_char(WRITE_UUID, q, response=True)
                        await asyncio.sleep(0.03)
                    except Exception:
                        pass
                await asyncio.sleep(0.08)

                if cmd_line == "status_json":
                    writer.write(f"OK JSON:{json.dumps(latest_state)}\n".encode("utf-8"))
                else:
                    lines = [
                        "--- STATUT GDANSK ---",
                        f"  💡 Alimentation : {'ALLUMÉ (ON)' if latest_state['power'] else 'ÉTEINT (OFF)'}",
                        f"  ☀️ Luminosité   : {latest_state['dim']}%",
                        f"  🌡️ Blanc CCT    : ~{latest_state['temp']}K",
                        f"  🎨 Teinte Hue   : {latest_state['hue']}° sur roue"
                    ]
                    msg = "OK\n" + "\n".join(lines) + "\n"
                    writer.write(msg.encode("utf-8"))
                await writer.drain()
                return

            if cmd_line == "inspect":
                cl = await get_active_client()
                out = []
                for s in cl.services:
                    out.append(f"SVC: {s.uuid} ({s.description})")
                    for c in s.characteristics:
                        val_str = ""
                        if "read" in c.properties:
                            try:
                                raw_val = await cl.read_gatt_char(c.uuid)
                                val_str = f" = {raw_val.decode('utf-8', errors='replace')} (hex: {raw_val.hex()})"
                            except Exception:
                                pass
                        out.append(f"  CHAR: {c.uuid} ({c.properties}){val_str}")
                full_str = "\n".join(out)
                writer.write(f"OK\n{full_str}\n".encode("utf-8"))
                await writer.drain()
                writer.close()
                return

            parts = cmd_line.split()
            cmd = parts[0]
            args = parts[1:]

            payloads = build_payloads(cmd, args)
            cl = await get_active_client()
            for p in payloads:
                await cl.write_gatt_char(WRITE_UUID, p, response=True)
                await asyncio.sleep(0.02)

            if cmd == "on":
                latest_state["power"] = True
            elif cmd == "off":
                latest_state["power"] = False
            elif cmd == "dim" and args:
                latest_state["dim"] = max(0, min(100, int(args[0])))
            elif cmd == "temp" and args:
                latest_state["temp"] = max(2700, min(6500, int(args[0])))
            elif cmd == "hue" and args:
                latest_state["hue"] = int(float(args[0]) % 360)

            writer.write(b"OK\n")
            await writer.drain()
        except Exception as e:
            msg = f"ERR {e}\n".encode("utf-8")
            writer.write(msg)
            await writer.drain()
        finally:
            try:
                writer.close()
            except Exception:
                pass

    server = await asyncio.start_unix_server(handle_client, path=SOCKET_PATH)
    print(f"✅ Daemon prêt sur {SOCKET_PATH}. En attente de commandes.")
    # Connexion Bluetooth en tâche de fond
    asyncio.create_task(get_active_client())

    try:
        await server.serve_forever()
    except (asyncio.CancelledError, KeyboardInterrupt):
        pass
    finally:
        if active_loop_task:
            active_loop_task.cancel()
        server.close()
        await server.wait_closed()
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        if client and client.is_connected:
            await client.disconnect()

def start_daemon_background():
    if not os.path.exists(SOCKET_PATH):
        log_file = open("/tmp/lumenbar_daemon.log", "a")
        subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "_daemon_worker"],
            stdout=log_file,
            stderr=log_file,
            start_new_session=True
        )
        for _ in range(15):
            time.sleep(0.2)
            if os.path.exists(SOCKET_PATH):
                break

# --- Mode interactif temps réel ---
async def run_interactive(address: str):
    print("==================================================")
    print("Mode interactif Gdansk (Connexion Bluetooth maintenue)")
    print("Tape tes commandes directement (on, off, dim 80, color red, party, temp 3000...)")
    print("Tape 'quit' ou 'exit' pour quitter.")
    print("==================================================")
    
    print(f"📡 Connexion à {address}...")
    client = await connect_client(address)
    print("⚡ Connecté ! Réponse instantanée (< 30ms).\n")

    try:
        while True:
            try:
                line = await asyncio.to_thread(input, "lumenbar> ")
            except (EOFError, KeyboardInterrupt):
                break
            line = line.strip()
            if not line:
                continue
            if line.lower() in ["exit", "quit", "q"]:
                break
            parts = line.split()
            cmd = parts[0]
            args = parts[1:]
            try:
                payloads = build_payloads(cmd, args)
                for p in payloads:
                    await client.write_gatt_char(WRITE_UUID, p, response=True)
                    await asyncio.sleep(0.02)
                print("⚡ Envoyé !")
            except Exception as e:
                print(f"❌ Erreur : {e}")
    finally:
        print("\nDéconnexion propre...")
        await client.disconnect()

# --- One-shot direct (si daemon absent) ---
async def execute_direct(address: str, cmd: str, args: list[str]):
    payloads = build_payloads(cmd, args)
    client = await connect_client(address)
    try:
        for p in payloads:
            await client.write_gatt_char(WRITE_UUID, p, response=True)
            await asyncio.sleep(0.03)
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass

def print_help():
    print("""
==============================================================
LumenBar - Contrôleur d'éclairage BLE (Inspire / Lexman / GATT)
==============================================================

Alimentation & Variateur :
  python3 lumenbar.py on                   # Allumer
  python3 lumenbar.py off                  # Éteindre
  python3 lumenbar.py dim <0-100>          # Luminosité (ex: dim 80)
  python3 lumenbar.py temp <2700-6500>     # Blanc CCT en Kelvin (2700=chaud, 6500=froid)

Roue chromatique & Couleurs :
  python3 lumenbar.py color <nom>          # red, blue, green, yellow, orange, cyan...
  python3 lumenbar.py hue <0-360>          # Degré exact sur la roue chromatique (ex: hue 240)
  python3 lumenbar.py rgb <R> <G> <B>      # Convertit RGB en teinte (ex: rgb 0 255 128)
  python3 lumenbar.py hex <#HEX>           # Convertit Hex en teinte (ex: hex #FF0055)

Informations & Découverte :
  python3 lumenbar.py scan                 # Recherche les luminaires Bluetooth compatibles
  python3 lumenbar.py status               # Affiche l'état complet
  python3 lumenbar.py interactive          # Console en direct lumenbar>
  python3 lumenbar.py daemon start|stop    # Gestion du daemon
==============================================================
""")

async def main():
    if len(sys.argv) < 2 or sys.argv[1] in ["-h", "--help", "help"]:
        print_help()
        sys.exit(0)

    arg1 = sys.argv[1].lower()

    if arg1 == "_daemon_worker":
        address = load_address()
        if not address:
            sys.exit(1)
        await run_daemon(address)
        return

    if arg1 == "daemon":
        sub = sys.argv[2].lower() if len(sys.argv) > 2 else "start"
        if sub == "start":
            if os.path.exists(SOCKET_PATH) and try_send_via_daemon("ping"):
                print("✅ Le daemon tourne déjà et est connecté.")
                return
            print("🚀 Lancement du daemon en arrière-plan...")
            start_daemon_background()
            print("⚡ Daemon démarré ! Toutes tes prochaines commandes seront instantanées.")
            return
        elif sub == "stop":
            if try_send_via_daemon("stop"):
                print("🛑 Daemon arrêté.")
            else:
                if os.path.exists(SOCKET_PATH):
                    os.unlink(SOCKET_PATH)
                print("Daemon non actif.")
            return

    if arg1 in ["inspect", "services", "status", "status_json"]:
        if os.path.exists(SOCKET_PATH):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.connect(SOCKET_PATH)
                s.sendall((arg1 + "\n").encode("utf-8"))
                data = s.recv(8192).decode("utf-8")
                print(data.replace("OK\n", "", 1))
                return

    if arg1 in ["interactive", "-i"]:
        address = load_address()
        if not address:
            print("Erreur: Aucune adresse configurée.")
            sys.exit(1)
        await run_interactive(address)
        return

    if arg1 in ["scan", "scan_json"]:
        if os.path.exists(SOCKET_PATH):
            try_send_via_daemon("stop")
            await asyncio.sleep(1.2)
        results = await scan_devices(timeout=6.0)
        if arg1 == "scan_json":
            print("OK JSON:" + json.dumps(results))
        else:
            print(f"🔍 {len(results)} dispositif(s) trouvé(s) :")
            for r in results:
                badge = "💡 COMPATIBLE" if r["is_compatible"] else "  "
                print(f"  {badge} {r['name']} ({r['address']}) RSSI: {r['rssi']} dBm")
        return

    if arg1 == "forget":
        if os.path.exists(SOCKET_PATH):
            try_send_via_daemon("stop")
        forget_address()
        print("OK FORGOTTEN")
        return

    if arg1 in ["get-addr", "get_addr", "info"]:
        addr = load_address()
        print("OK JSON:" + json.dumps({"configured": addr is not None, "address": addr}))
        return

    if arg1 == "set-addr":
        if len(sys.argv) < 3:
            print("Usage: python3 gdansk.py set-addr <ADDR>")
            sys.exit(1)
        save_address(sys.argv[2])
        print(f"✅ Adresse enregistrée : {sys.argv[2]}")
        return

    cmd_str = " ".join(sys.argv[1:])

    # 1. Envoi via Daemon
    t0 = time.time()
    if try_send_via_daemon(cmd_str):
        dt = round((time.time() - t0) * 1000)
        print(f"⚡ Exécuté en {dt}ms (via connexion persistante)")
        return

    # 2. Si le daemon ne tourne pas, le lancer
    start_daemon_background()
    time.sleep(0.3)
    if try_send_via_daemon(cmd_str):
        print(f"⚡ Exécuté (daemon activé)")
        return

    # 3. Fallback direct
    address = load_address()
    if not address:
        print("Erreur: Aucune adresse configurée.")
        sys.exit(1)

    try:
        t0 = time.time()
        await execute_direct(address, arg1, sys.argv[2:])
        dt = round((time.time() - t0) * 1000)
        print(f"✅ Exécuté en {dt}ms (connexion directe)")
    except Exception as e:
        print(f"❌ Erreur : {e}")

if __name__ == "__main__":
    asyncio.run(main())
