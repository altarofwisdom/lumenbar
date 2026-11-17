package com.altarofwisdom.lumenbar

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.altarofwisdom.lumenbar.databinding.ActivityMainBinding
import com.altarofwisdom.lumenbar.databinding.DialogScanBinding

@SuppressLint("MissingPermission", "SetTextI18n")
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var bleManager: BleManager
    private lateinit var autoLightEngine: AutoLightEngine
    private lateinit var prefs: SharedPreferences
    private val mainHandler = Handler(Looper.getMainLooper())

    private val PREFS_NAME = "lumenbar_prefs"
    private val KEY_PAIRED_MAC = "paired_mac"
    private val KEY_PAIRED_NAME = "paired_name"

    private var isPoweredOn = true
    private var currentBrightness = 50.0
    private var currentCCT = 4000.0
    private var currentHue = 0.0

    // Débouncing pour curseurs
    private var brightnessRunnable: Runnable? = null
    private var cctRunnable: Runnable? = null
    private var hueRunnable: Runnable? = null

    // Permissions Bluetooth et Localisation
    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        val grantedCount = permissions.count { it.value }
        Log.i("MainActivity", "Permissions: $grantedCount / ${permissions.size} granted")

        if (hasRequiredPermissions()) {
            ensureBluetoothEnabledAndStart()
        } else {
            Toast.makeText(this, R.string.permission_required, Toast.LENGTH_LONG).show()
        }
    }

    private val enableBtLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { _ ->
        if (bleManager.bluetoothAdapter?.isEnabled == true) {
            connectSavedOrPromptScan()
        } else {
            Toast.makeText(this, "Veuillez activer le Bluetooth pour contrôler votre luminaire", Toast.LENGTH_LONG).show()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        bleManager = BleManager(this)
        autoLightEngine = AutoLightEngine(this)

        setupListeners()
        setupAutoLight()
        setupColorDots()
        setupDiagnostics()

        requestAppPermissions()
    }

    override fun onDestroy() {
        super.onDestroy()
        autoLightEngine.isEnabled = false
        bleManager.disconnect()
    }

    private fun getRequiredPermissions(): List<String> {
        val list = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            list.add(Manifest.permission.BLUETOOTH_SCAN)
            list.add(Manifest.permission.BLUETOOTH_CONNECT)
            list.add(Manifest.permission.ACCESS_FINE_LOCATION)
        } else {
            list.add(Manifest.permission.ACCESS_FINE_LOCATION)
            list.add(Manifest.permission.ACCESS_COARSE_LOCATION)
        }
        return list
    }

    private fun hasRequiredPermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestAppPermissions() {
        val required = getRequiredPermissions()
        val missing = required.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (missing.isNotEmpty()) {
            permissionLauncher.launch(missing.toTypedArray())
        } else {
            ensureBluetoothEnabledAndStart()
        }
    }

    private fun ensureBluetoothEnabledAndStart() {
        val adapter = bleManager.bluetoothAdapter
        if (adapter == null) {
            Toast.makeText(this, "Bluetooth indisponible sur cet appareil", Toast.LENGTH_LONG).show()
            return
        }

        if (!adapter.isEnabled) {
            try {
                val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                enableBtLauncher.launch(enableBtIntent)
            } catch (e: Exception) {
                Log.e("MainActivity", "Cannot request enable BT", e)
            }
        } else {
            connectSavedOrPromptScan()
        }
    }

    private fun connectSavedOrPromptScan() {
        val savedMac = prefs.getString(KEY_PAIRED_MAC, null)
        if (!savedMac.isNullOrEmpty()) {
            val name = prefs.getString(KEY_PAIRED_NAME, "Luminaire")
            binding.tvStatus.text = "${getString(R.string.connecting)} ($name)"
            bleManager.connect(savedMac)
        } else {
            binding.tvStatus.text = getString(R.string.not_configured)
            showScanDialog()
        }
    }

    private fun setupListeners() {
        // BLE Callbacks
        bleManager.onConnectionStateChanged = { state ->
            when (state) {
                BleManager.ConnectionState.CONNECTED -> {
                    val name = prefs.getString(KEY_PAIRED_NAME, "Luminaire")
                    binding.tvStatus.text = "● ${getString(R.string.connected)} ($name)"
                    binding.tvStatus.setTextColor(getColor(R.color.accent_green))
                    Toast.makeText(this, "Connecté à $name", Toast.LENGTH_SHORT).show()
                    autoLightEngine.updateCurrentLampState(isPoweredOn, currentBrightness)
                }
                BleManager.ConnectionState.CONNECTING -> {
                    val name = prefs.getString(KEY_PAIRED_NAME, "Luminaire")
                    binding.tvStatus.text = "${getString(R.string.connecting)} ($name)"
                    binding.tvStatus.setTextColor(getColor(R.color.primary))
                }
                BleManager.ConnectionState.DISCONNECTED -> {
                    binding.tvStatus.text = getString(R.string.disconnected)
                    binding.tvStatus.setTextColor(getColor(R.color.text_secondary))
                }
            }
        }

        // Power Button
        binding.btnPower.setOnClickListener {
            isPoweredOn = !isPoweredOn
            updatePowerUI()
            bleManager.setPower(isPoweredOn)
            autoLightEngine.updateCurrentLampState(isPoweredOn, currentBrightness)
        }

        // Brightness Slider avec débouncing 60ms
        binding.sliderBrightness.addOnChangeListener { _, value, fromUser ->
            if (fromUser) {
                currentBrightness = value.toDouble()
                binding.tvBrightnessValue.text = "${value.toInt()} %"
                brightnessRunnable?.let { mainHandler.removeCallbacks(it) }
                val r = Runnable {
                    bleManager.setBrightness(currentBrightness)
                    autoLightEngine.updateCurrentLampState(isPoweredOn, currentBrightness)
                }
                brightnessRunnable = r
                mainHandler.postDelayed(r, 60)
            }
        }

        // Brightness Presets
        binding.btnDim25.setOnClickListener { setBrightnessPreset(25.0) }
        binding.btnDim50.setOnClickListener { setBrightnessPreset(50.0) }
        binding.btnDim75.setOnClickListener { setBrightnessPreset(75.0) }
        binding.btnDim100.setOnClickListener { setBrightnessPreset(100.0) }

        // CCT Slider avec débouncing 60ms
        binding.sliderCCT.addOnChangeListener { _, value, fromUser ->
            if (fromUser) {
                if (!isPoweredOn) {
                    isPoweredOn = true
                    updatePowerUI()
                    bleManager.setPower(true)
                }
                currentCCT = value.toDouble()
                updateCCTLabel(value.toInt())
                cctRunnable?.let { mainHandler.removeCallbacks(it) }
                val r = Runnable {
                    bleManager.setCCT(currentCCT)
                }
                cctRunnable = r
                mainHandler.postDelayed(r, 60)
            }
        }

        // CCT Presets
        binding.btnWarm.setOnClickListener { setCCTPreset(2700.0) }
        binding.btnNeutral.setOnClickListener { setCCTPreset(4000.0) }
        binding.btnCool.setOnClickListener { setCCTPreset(6500.0) }

        // Hue Slider avec débouncing 60ms
        binding.sliderHue.addOnChangeListener { _, value, fromUser ->
            if (fromUser) {
                if (!isPoweredOn) {
                    isPoweredOn = true
                    updatePowerUI()
                    bleManager.setPower(true)
                }
                currentHue = value.toDouble()
                binding.tvHueValue.text = "${value.toInt()}°"
                val color = Color.HSVToColor(floatArrayOf(value, 1.0f, 1.0f))
                binding.tvHueValue.setTextColor(color)
                binding.sliderHue.thumbTintList = android.content.res.ColorStateList.valueOf(color)
                binding.sliderHue.trackActiveTintList = android.content.res.ColorStateList.valueOf(color)

                hueRunnable?.let { mainHandler.removeCallbacks(it) }
                val r = Runnable {
                    bleManager.setHue(currentHue)
                }
                hueRunnable = r
                mainHandler.postDelayed(r, 60)
            }
        }

        // Scan Dialog Button
        binding.btnScanDialog.setOnClickListener {
            if (!hasRequiredPermissions()) {
                requestAppPermissions()
            } else {
                showScanDialog()
            }
        }
    }

    private fun setupDiagnostics() {
        bleManager.onGattStatusChanged = { text ->
            binding.tvDiagGatt.text = text
        }

        bleManager.onCharStatusChanged = { text ->
            binding.tvDiagChar.text = text
        }

        bleManager.onWriteStatusChanged = { text, ok ->
            binding.tvDiagLastCmd.text = "Trame : $text"
            binding.tvDiagLastCmd.setTextColor(if (ok) getColor(R.color.accent_green) else getColor(R.color.accent_red))
        }

        binding.btnDiagForceOn.setOnClickListener {
            bleManager.setPower(true)
            isPoweredOn = true
            updatePowerUI()
        }

        binding.btnDiagForceOff.setOnClickListener {
            bleManager.setPower(false)
            isPoweredOn = false
            updatePowerUI()
        }
    }

    private fun setupAutoLight() {
        if (!autoLightEngine.hasLightSensor) {
            binding.switchAutoLight.isEnabled = false
            binding.tvAutoLightStatus.text = getString(R.string.sensor_not_available)
            return
        }

        binding.switchAutoLight.setOnCheckedChangeListener { _, isChecked ->
            autoLightEngine.isEnabled = isChecked
            binding.layoutAutoLightControls.visibility = if (isChecked) View.VISIBLE else View.GONE
        }

        binding.sliderTargetComfort.addOnChangeListener { _, value, fromUser ->
            if (fromUser) {
                autoLightEngine.targetComfortPercent = value.toDouble()
                binding.tvTargetComfort.text = "${value.toInt()} %"
            }
        }

        binding.switchAutoPower.setOnCheckedChangeListener { _, isChecked ->
            autoLightEngine.autoPowerEnabled = isChecked
        }

        autoLightEngine.onLuxChanged = { lux, percent ->
            binding.tvMeasuredLux.text = "${lux.toInt()} Lux (${percent.toInt()}%)"
            binding.progressMeasuredLux.progress = percent.toInt()
        }

        autoLightEngine.onStatusChanged = { status ->
            binding.tvAutoLightStatus.text = status
        }

        autoLightEngine.onBrightnessAdjustment = { newBrightness ->
            currentBrightness = newBrightness
            binding.sliderBrightness.value = newBrightness.toFloat()
            binding.tvBrightnessValue.text = "${newBrightness.toInt()} %"
            bleManager.setBrightness(newBrightness)
        }

        autoLightEngine.onPowerAdjustment = { on ->
            isPoweredOn = on
            updatePowerUI()
            bleManager.setPower(on)
        }
    }

    private fun updatePowerUI() {
        if (isPoweredOn) {
            binding.btnPower.backgroundTintList = ContextCompat.getColorStateList(this, R.color.accent_green)
        } else {
            binding.btnPower.backgroundTintList = ContextCompat.getColorStateList(this, R.color.surface_variant)
        }
    }

    private fun setBrightnessPreset(percent: Double) {
        if (!isPoweredOn) {
            isPoweredOn = true
            updatePowerUI()
            bleManager.setPower(true)
        }
        currentBrightness = percent
        binding.sliderBrightness.value = percent.toFloat()
        binding.tvBrightnessValue.text = "${percent.toInt()} %"
        bleManager.setBrightness(percent)
        autoLightEngine.updateCurrentLampState(isPoweredOn, percent)
    }

    private fun setCCTPreset(kelvin: Double) {
        if (!isPoweredOn) {
            isPoweredOn = true
            updatePowerUI()
            bleManager.setPower(true)
        }
        currentCCT = kelvin
        binding.sliderCCT.value = kelvin.toFloat()
        updateCCTLabel(kelvin.toInt())
        bleManager.setCCT(kelvin)
    }

    private fun updateCCTLabel(k: Int) {
        val qualifier = when {
            k < 3300 -> getString(R.string.warm_2700k)
            k < 5000 -> getString(R.string.neutral_4000k)
            else -> getString(R.string.cool_6500k)
        }
        binding.tvCCTValue.text = "$k K ($qualifier)"
    }

    private fun setupColorDots() {
        val dots = listOf(
            binding.dotRed to 0.0,
            binding.dotOrange to 30.0,
            binding.dotYellow to 60.0,
            binding.dotGreen to 120.0,
            binding.dotCyan to 180.0,
            binding.dotBlue to 240.0,
            binding.dotPurple to 280.0,
            binding.dotPink to 330.0
        )

        dots.forEach { (view, hue) ->
            view.setOnClickListener {
                if (!isPoweredOn) {
                    isPoweredOn = true
                    updatePowerUI()
                    bleManager.setPower(true)
                }
                currentHue = hue
                binding.sliderHue.value = hue.toFloat()
                binding.tvHueValue.text = "${hue.toInt()}°"
                val color = Color.HSVToColor(floatArrayOf(hue.toFloat(), 1.0f, 1.0f))
                binding.tvHueValue.setTextColor(color)
                binding.sliderHue.thumbTintList = android.content.res.ColorStateList.valueOf(color)
                binding.sliderHue.trackActiveTintList = android.content.res.ColorStateList.valueOf(color)
                bleManager.setHue(hue)
            }
        }
    }

    // MARK: - Scan Dialog
    private fun showScanDialog() {
        if (!hasRequiredPermissions()) {
            requestAppPermissions()
            return
        }

        val dialogBinding = DialogScanBinding.inflate(layoutInflater)
        val dialog = AlertDialog.Builder(this)
            .setView(dialogBinding.root)
            .create()

        val foundDevices = mutableListOf<BleManager.DiscoveredLamp>()
        val adapter = object : ArrayAdapter<BleManager.DiscoveredLamp>(
            this,
            android.R.layout.simple_list_item_2,
            android.R.id.text1,
            foundDevices
        ) {
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                val view = super.getView(position, convertView, parent)
                val text1 = view.findViewById<TextView>(android.R.id.text1)
                val text2 = view.findViewById<TextView>(android.R.id.text2)
                val item = getItem(position)

                if (item?.isCompatible == true) {
                    text1.text = "💡 ${item.name}  ★"
                    text1.setTextColor(getColor(R.color.primary))
                } else {
                    text1.text = item?.name ?: "Inconnu"
                    text1.setTextColor(getColor(R.color.text_primary))
                }
                text2.setTextColor(getColor(R.color.text_secondary))
                text2.text = "${item?.address}   Signal: ${item?.rssi} dBm"
                return view
            }
        }
        dialogBinding.lvDevices.adapter = adapter

        val currentMac = prefs.getString(KEY_PAIRED_MAC, null)
        if (!currentMac.isNullOrEmpty()) {
            val currentName = prefs.getString(KEY_PAIRED_NAME, "Luminaire")
            dialogBinding.tvPairedInfo.text = "$currentName ($currentMac)"
            dialogBinding.btnForget.visibility = View.VISIBLE
        }

        dialogBinding.btnForget.setOnClickListener {
            prefs.edit().remove(KEY_PAIRED_MAC).remove(KEY_PAIRED_NAME).apply()
            dialogBinding.tvPairedInfo.text = getString(R.string.not_configured)
            dialogBinding.btnForget.visibility = View.GONE
            bleManager.disconnect()
            binding.tvStatus.text = getString(R.string.not_configured)
            binding.tvStatus.setTextColor(getColor(R.color.text_secondary))
        }

        dialogBinding.lvDevices.setOnItemClickListener { _, _, position, _ ->
            val chosen = foundDevices[position]
            prefs.edit()
                .putString(KEY_PAIRED_MAC, chosen.address)
                .putString(KEY_PAIRED_NAME, chosen.name)
                .apply()

            bleManager.stopScan()
            binding.tvStatus.text = "${getString(R.string.connecting)} (${chosen.name})"
            binding.tvStatus.setTextColor(getColor(R.color.primary))
            dialog.dismiss()

            // Délai de 250ms indispensable avant connectGatt
            mainHandler.postDelayed({
                bleManager.connect(chosen.address)
            }, 250)
        }

        dialogBinding.btnStartScan.setOnClickListener {
            foundDevices.clear()
            adapter.notifyDataSetChanged()
            dialogBinding.progressScan.visibility = View.VISIBLE
            dialogBinding.btnStartScan.isEnabled = false

            bleManager.onDeviceDiscovered = { lamp ->
                if (foundDevices.none { it.address == lamp.address }) {
                    foundDevices.add(lamp)
                    foundDevices.sortWith(compareByDescending<BleManager.DiscoveredLamp> { it.isCompatible }.thenByDescending { it.rssi })
                    adapter.notifyDataSetChanged()
                }
            }

            bleManager.onScanFinished = {
                dialogBinding.progressScan.visibility = View.GONE
                dialogBinding.btnStartScan.isEnabled = true
                if (foundDevices.isEmpty()) {
                    Toast.makeText(this@MainActivity, R.string.no_devices_found, Toast.LENGTH_SHORT).show()
                }
            }

            bleManager.startScan()
        }

        dialog.show()
        dialogBinding.btnStartScan.performClick()
    }
}
