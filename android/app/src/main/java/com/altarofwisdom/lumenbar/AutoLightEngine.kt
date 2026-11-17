package com.altarofwisdom.lumenbar

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import kotlin.math.abs
import kotlin.math.roundToInt

class AutoLightEngine(private val context: Context) : SensorEventListener {

    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val lightSensor = sensorManager.getDefaultSensor(Sensor.TYPE_LIGHT)
    private val mainHandler = Handler(Looper.getMainLooper())

    var isEnabled: Boolean = false
        set(value) {
            field = value
            if (value) start() else stop()
        }

    var targetComfortPercent: Double = 50.0 // 0% à 100% (mappé sur 0 à 600 lux)
    var autoPowerEnabled: Boolean = true

    // Callbacks
    var onBrightnessAdjustment: ((Double) -> Unit)? = null
    var onPowerAdjustment: ((Boolean) -> Unit)? = null
    var onLuxChanged: ((Float, Double) -> Unit)? = null // lux, normalized %
    var onStatusChanged: ((String) -> Unit)? = null

    // Internal State
    private var isRunning = false
    private var smoothedLux: Float = 0f
    private var lastRawLux: Float = 0f
    private var currentLampBrightness: Double = 50.0
    private var isLampOn: Boolean = true
    private var excessLightCycles: Int = 0

    private val loopIntervalMs = 1800L
    private val loopRunnable = object : Runnable {
        override fun run() {
            if (isRunning) {
                runRegulationCycle()
                mainHandler.postDelayed(this, loopIntervalMs)
            }
        }
    }

    val hasLightSensor: Boolean get() = lightSensor != null

    fun updateCurrentLampState(on: Boolean, brightness: Double) {
        this.isLampOn = on
        this.currentLampBrightness = brightness
    }

    private fun start() {
        if (isRunning || lightSensor == null) return
        isRunning = true
        sensorManager.registerListener(this, lightSensor, SensorManager.SENSOR_DELAY_NORMAL)
        mainHandler.post(loopRunnable)
        onStatusChanged?.invoke(context.getString(R.string.lighting_stable))
    }

    private fun stop() {
        if (!isRunning) return
        isRunning = false
        sensorManager.unregisterListener(this)
        mainHandler.removeCallbacks(loopRunnable)
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event == null || event.sensor.type != Sensor.TYPE_LIGHT) return
        val lux = event.values[0]
        lastRawLux = lux

        // Lissage passe-bas EMA
        smoothedLux = if (smoothedLux == 0f) lux else (0.80f * smoothedLux + 0.20f * lux)

        val normalizedPercent = (smoothedLux / 600.0 * 100.0).coerceIn(0.0, 100.0)
        mainHandler.post {
            onLuxChanged?.invoke(smoothedLux, normalizedPercent)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun runRegulationCycle() {
        if (!isLampOn) {
            // Mode Veille automatique
            if (autoPowerEnabled) {
                val currentPercent = (smoothedLux / 600.0 * 100.0).coerceIn(0.0, 100.0)
                val wakeThreshold = (targetComfortPercent - 4.0).coerceAtLeast(1.0)
                if (currentPercent < wakeThreshold) {
                    excessLightCycles = 0
                    onStatusChanged?.invoke(context.getString(R.string.soft_wake))
                    onPowerAdjustment?.invoke(true)
                    onBrightnessAdjustment?.invoke(10.0)
                } else {
                    onStatusChanged?.invoke(context.getString(R.string.standby_daylight))
                }
            }
            return
        }

        val measuredPercent = (smoothedLux / 600.0 * 100.0).coerceIn(0.0, 100.0)
        val error = targetComfortPercent - measuredPercent

        // Bande morte ±2%
        if (abs(error) <= 2.0) {
            excessLightCycles = 0
            onStatusChanged?.invoke(context.getString(R.string.lighting_stable))
            return
        }

        // Extinction automatique en cas d'excès de lumière du jour
        if (autoPowerEnabled && currentLampBrightness <= 5.0 && error < -3.0) {
            excessLightCycles++
            if (excessLightCycles >= 2) {
                onStatusChanged?.invoke(context.getString(R.string.standby_daylight))
                onPowerAdjustment?.invoke(false)
                excessLightCycles = 0
                return
            }
        } else {
            excessLightCycles = 0
        }

        // Régulation en boucle fermée proportionnelle (gain 0.40) avec pas max de 1%
        val gain = 0.40
        var delta = error * gain
        delta = delta.coerceIn(-1.0, 1.0) // Slew rate limiter à 1% par cycle

        val newBrightness = (currentLampBrightness + delta).coerceIn(1.0, 100.0)
        currentLampBrightness = newBrightness

        val statusStr = if (delta > 0) {
            context.getString(R.string.compensating_plus)
        } else {
            context.getString(R.string.compensating_minus)
        }
        onStatusChanged?.invoke(statusStr)
        onBrightnessAdjustment?.invoke(newBrightness)
    }
}
