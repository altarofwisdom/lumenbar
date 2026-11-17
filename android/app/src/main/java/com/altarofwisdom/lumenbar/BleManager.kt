package com.altarofwisdom.lumenbar

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.*
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.math.roundToInt

@SuppressLint("MissingPermission")
class BleManager(private val context: Context) {

    companion object {
        private const val TAG = "BleManager"

        val WRITE_UUID: UUID = UUID.fromString("0000a101-1115-1000-0001-617573746f6d")
        val READ_UUID: UUID = UUID.fromString("0000a102-1115-1000-0001-617573746f6d")
    }

    enum class ConnectionState {
        DISCONNECTED,
        CONNECTING,
        CONNECTED
    }

    data class DiscoveredLamp(
        val name: String,
        val address: String,
        val rssi: Int,
        val isCompatible: Boolean,
        val device: BluetoothDevice
    )

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    val bluetoothAdapter: BluetoothAdapter? get() = bluetoothManager.adapter
    private val mainHandler = Handler(Looper.getMainLooper())

    private var bluetoothGatt: BluetoothGatt? = null
    var writeCharacteristic: BluetoothGattCharacteristic? = null
        private set

    private val writeQueue = ConcurrentLinkedQueue<ByteArray>()
    private var isWriting = false
    var isColorMode: Boolean = false
        private set

    var onConnectionStateChanged: ((ConnectionState) -> Unit)? = null
    var onDeviceDiscovered: ((DiscoveredLamp) -> Unit)? = null
    var onScanFinished: (() -> Unit)? = null
    
    // Diagnostics en direct
    var onGattStatusChanged: ((String) -> Unit)? = null
    var onCharStatusChanged: ((String) -> Unit)? = null
    var onWriteStatusChanged: ((String, Boolean) -> Unit)? = null

    var currentState: ConnectionState = ConnectionState.DISCONNECTED
        private set(value) {
            field = value
            mainHandler.post { onConnectionStateChanged?.invoke(value) }
        }

    // MARK: - Scanning
    var isScanning = false
        private set

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            var rawName = device.name ?: result.scanRecord?.deviceName
            val name = if (rawName.isNullOrBlank()) "Périphérique Bluetooth" else rawName

            val nLow = name.lowercase()
            val serviceUuids = result.scanRecord?.serviceUuids?.map { it.uuid.toString().lowercase() } ?: emptyList()

            val isCompatible = nLow.contains("inspire") ||
                    nLow.contains("lexman") ||
                    nLow.contains("gdansk") ||
                    nLow.contains("zbek") ||
                    nLow.contains("bulb") ||
                    nLow.contains("lamp") ||
                    nLow.contains("light") ||
                    nLow.contains("led") ||
                    nLow.contains("smart") ||
                    nLow.contains("lum") ||
                    serviceUuids.any { it.contains("a101") || it.contains("a100") }

            val lamp = DiscoveredLamp(name, device.address, result.rssi, isCompatible, device)
            mainHandler.post { onDeviceDiscovered?.invoke(lamp) }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>?) {
            results?.forEach { onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, it) }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "BLE Scan failed: $errorCode")
            stopScan()
        }
    }

    fun startScan(durationMs: Long = 8000L) {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            mainHandler.post { onScanFinished?.invoke() }
            return
        }

        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            mainHandler.post { onScanFinished?.invoke() }
            return
        }

        if (isScanning) return
        isScanning = true

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        try {
            scanner.startScan(null, settings, scanCallback)
            Log.i(TAG, "Unfiltered BLE Scan started")
        } catch (e: Exception) {
            Log.e(TAG, "startScan error", e)
            isScanning = false
            mainHandler.post { onScanFinished?.invoke() }
            return
        }

        mainHandler.postDelayed({ stopScan() }, durationMs)
    }

    fun stopScan() {
        if (!isScanning) return
        isScanning = false
        try {
            bluetoothAdapter?.bluetoothLeScanner?.stopScan(scanCallback)
            Log.i(TAG, "BLE Scan stopped")
        } catch (e: Exception) {
            Log.e(TAG, "stopScan error", e)
        }
        mainHandler.post { onScanFinished?.invoke() }
    }

    // MARK: - Connection
    fun connect(address: String) {
        val adapter = bluetoothAdapter ?: return
        val device = try {
            adapter.getRemoteDevice(address)
        } catch (e: Exception) {
            Log.e(TAG, "Invalid MAC: $address", e)
            mainHandler.post { onGattStatusChanged?.invoke("GATT : Adresse MAC invalide") }
            return
        }

        disconnect()
        currentState = ConnectionState.CONNECTING
        mainHandler.post { onGattStatusChanged?.invoke("GATT : Connexion en cours vers $address...") }

        mainHandler.postDelayed({
            try {
                bluetoothGatt = device.connectGatt(
                    context,
                    false,
                    gattCallback,
                    BluetoothDevice.TRANSPORT_LE
                )
            } catch (e: Exception) {
                Log.e(TAG, "connectGatt error", e)
                currentState = ConnectionState.DISCONNECTED
                mainHandler.post { onGattStatusChanged?.invoke("GATT : Erreur ${e.message}") }
            }
        }, 150)
    }

    fun disconnect() {
        try {
            bluetoothGatt?.disconnect()
            bluetoothGatt?.close()
        } catch (e: Exception) {
            Log.e(TAG, "disconnect error", e)
        }
        bluetoothGatt = null
        writeCharacteristic = null
        writeQueue.clear()
        isWriting = false
        isColorMode = false
        currentState = ConnectionState.DISCONNECTED
        mainHandler.post { 
            onGattStatusChanged?.invoke("GATT : Déconnecté")
            onCharStatusChanged?.invoke("Caractéristique : Aucune")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            Log.d(TAG, "onConnectionStateChange: status=$status, newState=$newState")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(TAG, "Connection failed: status=$status")
                mainHandler.post { onGattStatusChanged?.invoke("GATT : Échec statut $status") }
                disconnect()
                return
            }

            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    mainHandler.post { onGattStatusChanged?.invoke("GATT : Connecté ! Découverte services...") }
                    gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                    
                    mainHandler.postDelayed({
                        val ok = gatt.discoverServices()
                        Log.i(TAG, "discoverServices: $ok")
                    }, 250)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    mainHandler.post { onGattStatusChanged?.invoke("GATT : Déconnecté") }
                    disconnect()
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "onServicesDiscovered error: status=$status")
                mainHandler.post { onGattStatusChanged?.invoke("GATT : Erreur découverte services ($status)") }
                disconnect()
                return
            }

            Log.i(TAG, "Services discovered: ${gatt.services.size}")
            var foundWriteChar: BluetoothGattCharacteristic? = null

            // Parcours exhaustif de toutes les caractéristiques
            for (service in gatt.services) {
                for (char in service.characteristics) {
                    val uStr = char.uuid.toString().lowercase()
                    if (uStr.contains("a101")) {
                        foundWriteChar = char
                        break
                    }
                }
                if (foundWriteChar != null) break
            }

            // Fallback : première caractéristique inscriptible d'un service non standard
            if (foundWriteChar == null) {
                foundWriteChar = gatt.services
                    .filterNot { it.uuid.toString().startsWith("000018") }
                    .flatMap { it.characteristics }
                    .firstOrNull {
                        (it.properties and (BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE)) != 0
                    }
            }

            if (foundWriteChar != null) {
                writeCharacteristic = foundWriteChar

                val supportsWrite = (foundWriteChar.properties and BluetoothGattCharacteristic.PROPERTY_WRITE) != 0
                val supportsNoResp = (foundWriteChar.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
                
                foundWriteChar.writeType = if (supportsWrite) {
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                } else if (supportsNoResp) {
                    BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                } else {
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                }

                val charInfo = "${foundWriteChar.uuid.toString().take(8)}... (Type=${if (foundWriteChar.writeType == BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) "WithResp" else "NoResp"})"
                mainHandler.post {
                    onGattStatusChanged?.invoke("GATT : Prêt (${gatt.services.size} services)")
                    onCharStatusChanged?.invoke("Caractéristique : $charInfo")
                }

                currentState = ConnectionState.CONNECTED
                mainHandler.postDelayed({ processNextWrite() }, 100)
            } else {
                mainHandler.post {
                    onCharStatusChanged?.invoke("Caractéristique : AUCUNE inscriptible trouvée !")
                }
                disconnect()
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            Log.d(TAG, "onCharacteristicWrite: status=$status")
            isWriting = false
            mainHandler.post { processNextWrite() }
        }
    }

    // MARK: - Write Queue
    fun queueWrite(bytes: ByteArray, desc: String = "") {
        writeQueue.add(bytes)
        mainHandler.post { processNextWrite() }
    }

    private fun processNextWrite() {
        val gatt = bluetoothGatt
        val char = writeCharacteristic

        if (gatt == null || char == null) {
            if (currentState == ConnectionState.CONNECTED) {
                mainHandler.post { onWriteStatusChanged?.invoke("Erreur : Liaison ou caractéristique non prête", false) }
            }
            return
        }

        if (isWriting) return

        val bytes = writeQueue.poll() ?: return
        isWriting = true

        val hexStr = bytes.joinToString("") { "%02X".format(it) }

        @Suppress("DEPRECATION")
        char.value = bytes
        @Suppress("DEPRECATION")
        char.writeType = char.writeType

        val success = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val code = gatt.writeCharacteristic(char, bytes, char.writeType)
            code == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            gatt.writeCharacteristic(char)
        }

        mainHandler.post {
            onWriteStatusChanged?.invoke("$hexStr (${if (success) "Envoyé" else "Échec"})", success)
        }

        if (success) {
            // Déblocage automatique après temporisation courte
            mainHandler.postDelayed({
                if (isWriting) {
                    isWriting = false
                    processNextWrite()
                }
            }, 60)
        } else {
            // Ne pas boucler à l'infini : attendre 100ms et passer au paquet suivant
            mainHandler.postDelayed({
                isWriting = false
                processNextWrite()
            }, 100)
        }
    }

    // MARK: - Commands
    fun setPower(on: Boolean) {
        val payload = if (on) {
            byteArrayOf(0x00, 0x00, 0x10, 0x01, 0x03, 0x01, 0x00, 0x00)
        } else {
            byteArrayOf(0x00, 0x00, 0x10, 0x01, 0x03, 0x00, 0x00, 0x00)
        }
        queueWrite(payload, if (on) "ON" else "OFF")
    }

    fun setBrightness(percent: Double) {
        val clamped = percent.coerceIn(0.0, 100.0)
        val raw = ((clamped / 100.0) * 0xFE).roundToInt().coerceIn(0, 0xFE)
        val payload = byteArrayOf(0x00, 0x00, 0x11, 0x01, 0x03, raw.toByte(), 0x00, 0x00)
        queueWrite(payload, "Dim ${clamped.roundToInt()}%")
    }

    fun setCCT(kelvin: Double) {
        isColorMode = false
        val clamped = kelvin.coerceIn(2700.0, 6500.0)
        val cct = ((clamped - 6500.0) * (454.0 - 156.0) / (2700.0 - 6500.0) + 156.0).roundToInt().coerceIn(156, 454)
        val b0 = (cct and 0xFF).toByte()
        val b1 = ((cct shr 8) and 0xFF).toByte()
        val payload = byteArrayOf(0x00, 0x00, 0x12, 0x01, 0x04, b1, b0, 0x00, 0x00)
        queueWrite(payload, "CCT ${clamped.roundToInt()}K")
    }

    fun setHue(hueDeg: Double) {
        if (!isColorMode) {
            isColorMode = true
            // Extinction physique du canal blanc froid (CW) lors de la transition depuis le mode CCT
            // (notamment 6500K) en positionnant CCT à 2700K (CW = 0%) juste avant la trame de teinte
            val cctResetPayload = byteArrayOf(0x00, 0x00, 0x12, 0x01, 0x04, 0x01.toByte(), 0xC6.toByte(), 0x00, 0x00)
            queueWrite(cctResetPayload, "Transition Couleur (Extinction CW)")
        }

        val clamped = hueDeg.coerceIn(0.0, 360.0)
        val raw = ((clamped / 360.0) * 0xFE).roundToInt().coerceIn(0, 0xFE)
        val payload = byteArrayOf(0x00, 0x00, 0x13, 0x01, 0x03, raw.toByte(), 0x00, 0x00)
        queueWrite(payload, "Hue ${clamped.roundToInt()}°")
    }
}
