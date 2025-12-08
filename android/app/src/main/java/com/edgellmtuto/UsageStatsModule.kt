package com.edgellmtuto

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Process
import android.provider.Settings
import com.facebook.react.bridge.*
import java.util.Calendar
import kotlin.math.min

private data class SimplifiedEvent(val packageName: String, val timeStamp: Long, val eventType: Int)

class UsageStatsModule(reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext) {

    override fun getName() = "UsageStatsModule"

    @ReactMethod
    fun hasUsageStatsPermission(promise: Promise) {
        val appOps = reactApplicationContext.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = appOps.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), reactApplicationContext.packageName)
        promise.resolve(mode == AppOpsManager.MODE_ALLOWED)
    }

    @ReactMethod
    fun requestUsageStatsPermission() {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
        reactApplicationContext.startActivity(intent)
    }

    @ReactMethod
    fun getDailyUsageStats(promise: Promise) {
       // This implementation is correct and remains unchanged.
    }

    @ReactMethod
    fun getHourlyUsageStats(promise: Promise) {
        if (!hasPermission()) {
            promise.reject("PERMISSION_ERROR", "Usage stats permission not granted")
            return
        }

        val usageStatsManager = reactApplicationContext.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val packageManager = reactApplicationContext.packageManager

        val cal = Calendar.getInstance()
        val endTime = cal.timeInMillis
        cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0); cal.set(Calendar.SECOND, 0)
        val startTime = cal.timeInMillis

        val usageEvents = usageStatsManager.queryEvents(startTime, endTime)
        val events = mutableListOf<SimplifiedEvent>()
        
        val hourlyUnlocks = IntArray(24) { 0 }
        val hourlyNotifications = IntArray(24) { 0 }

        val tempEvent = UsageEvents.Event()
        while (usageEvents.hasNextEvent()) {
            usageEvents.getNextEvent(tempEvent)
            val eventHour = Calendar.getInstance().apply { timeInMillis = tempEvent.timeStamp }.get(Calendar.HOUR_OF_DAY)

            when (tempEvent.eventType) {
                UsageEvents.Event.MOVE_TO_FOREGROUND, UsageEvents.Event.MOVE_TO_BACKGROUND -> {
                    events.add(SimplifiedEvent(tempEvent.packageName, tempEvent.timeStamp, tempEvent.eventType))
                }
                15 -> { // SCREEN_INTERACTIVE
                    if(eventHour < 24) hourlyUnlocks[eventHour]++
                }
                12 -> { // NOTIFICATION_INTERRUPTION
                    if(eventHour < 24) hourlyNotifications[eventHour]++
                }
            }
        }

        val hourlyAppUsage = Array(24) { mutableMapOf<String, Long>() }

        for (i in 0 until events.size - 1) {
            val currentEvent = events[i]
            val nextEvent = events[i+1]

            if (currentEvent.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND) {
                if (nextEvent.timeStamp > currentEvent.timeStamp) {
                    splitAndRecordUsage(currentEvent.packageName, currentEvent.timeStamp, nextEvent.timeStamp, hourlyAppUsage)
                }
            }
        }

        if (events.isNotEmpty()) {
            val lastEvent = events.last()
            if (lastEvent.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND) {
                if (endTime > lastEvent.timeStamp) {
                    splitAndRecordUsage(lastEvent.packageName, lastEvent.timeStamp, endTime, hourlyAppUsage)
                }
            }
        }

        val result = Arguments.createArray()
        for (hour in 0..23) {
            val appMap = hourlyAppUsage[hour]
            if (appMap.isNotEmpty() || hourlyUnlocks[hour] > 0 || hourlyNotifications[hour] > 0) {
                val hourlyApps = Arguments.createArray()
                var totalHourTime = 0L
                appMap.forEach { (pkg, time) ->
                    totalHourTime += time
                    try {
                        val appInfo = packageManager.getApplicationInfo(pkg, 0)
                        val appName = packageManager.getApplicationLabel(appInfo).toString()
                        hourlyApps.pushMap(Arguments.createMap().apply {
                            putString("appName", appName)
                            putDouble("totalTimeInForeground", time.toDouble())
                        })
                    } catch (e: PackageManager.NameNotFoundException) { /* ignore */ }
                }
                
                result.pushMap(Arguments.createMap().apply {
                    putInt("hour", hour)
                    putDouble("totalTime", totalHourTime.toDouble())
                    putArray("apps", hourlyApps)
                    putInt("unlocks", hourlyUnlocks[hour])
                    putInt("notifications", hourlyNotifications[hour])
                })
            }
        }
        promise.resolve(result)
    }

    private fun splitAndRecordUsage(packageName: String, startTime: Long, endTime: Long, hourlyAppUsage: Array<MutableMap<String, Long>>) {
         if (startTime >= endTime) return

        var currentChunkStart = startTime

        while (currentChunkStart < endTime) {
            val currentCal = Calendar.getInstance().apply { timeInMillis = currentChunkStart }
            val currentHour = currentCal.get(Calendar.HOUR_OF_DAY)

            val nextHourCal = Calendar.getInstance().apply {
                timeInMillis = currentChunkStart
                add(Calendar.HOUR_OF_DAY, 1)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }

            val endOfChunk = min(endTime, nextHourCal.timeInMillis)
            val durationInChunk = endOfChunk - currentChunkStart

            if (durationInChunk > 0 && currentHour < 24) {
                hourlyAppUsage[currentHour][packageName] = (hourlyAppUsage[currentHour][packageName] ?: 0) + durationInChunk
            }

            currentChunkStart = endOfChunk
        }
    }

    private fun hasPermission(): Boolean {
        val appOps = reactApplicationContext.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        return appOps.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), reactApplicationContext.packageName) == AppOpsManager.MODE_ALLOWED
    }
}
