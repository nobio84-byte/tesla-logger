#!/usr/bin/env bash
set -e
echo "== generating android project =="
rm -rf app
mkdir -p app/src/main/java/com/jh/drivelog

cat > settings.gradle <<'EOF'
pluginManagement {
  repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
  repositories { google(); mavenCentral() }
}
rootProject.name = "drivelog"
include ":app"
EOF

cat > build.gradle <<'EOF'
plugins {
  id 'com.android.application' version '8.5.0' apply false
  id 'org.jetbrains.kotlin.android' version '1.9.24' apply false
}
EOF

cat > gradle.properties <<'EOF'
org.gradle.jvmargs=-Xmx2048m
android.useAndroidX=true
kotlin.code.style=official
EOF

cat > app/build.gradle <<'EOF'
plugins {
  id 'com.android.application'
  id 'org.jetbrains.kotlin.android'
}
android {
  namespace 'com.jh.drivelog'
  compileSdk 34
  defaultConfig {
    applicationId "com.jh.drivelog"
    minSdk 26
    targetSdk 28
    versionCode 1
    versionName "1.0"
  }
  compileOptions {
    sourceCompatibility JavaVersion.VERSION_17
    targetCompatibility JavaVersion.VERSION_17
  }
  kotlinOptions { jvmTarget = '17' }
}
EOF

cat > app/src/main/AndroidManifest.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.INTERNET"/>
  <uses-permission android:name="android.permission.BLUETOOTH"/>
  <uses-permission android:name="android.permission.BLUETOOTH_ADMIN"/>
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
  <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
  <application
      android:label="DriveLog"
      android:theme="@android:style/Theme.Material.Light.DarkActionBar">
    <activity android:name=".MainActivity" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
    <service android:name=".LoggerService" android:exported="false"/>
    <receiver android:name=".BootReceiver" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.BOOT_COMPLETED"/>
      </intent-filter>
    </receiver>
  </application>
</manifest>
EOF

cat > app/src/main/java/com/jh/drivelog/Api.kt <<'EOF'
package com.jh.drivelog

import android.content.SharedPreferences
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

object Api {
  private const val CID = "b60e10ca-556c-44bd-98c6-19dbb43c7bb3"
  private const val AUD = "https://fleet-api.prd.na.vn.cloud.tesla.com"

  fun accessToken(sp: SharedPreferences): String {
    val refresh = sp.getString("refresh", "") ?: ""
    val body = "grant_type=refresh_token&client_id=" + CID + "&refresh_token=" + refresh
    val tok = JSONObject(post("https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token", body, null))
    sp.edit().putString("refresh", tok.optString("refresh_token", refresh)).apply()
    return tok.getString("access_token")
  }

  fun vehicleId(at: String): String {
    val arr = JSONObject(get(AUD + "/api/1/vehicles", at)).getJSONArray("response")
    return arr.getJSONObject(0).getString("id")
  }

  fun location(at: String, vid: String): Pair<Double, Double>? {
    val vd = JSONObject(get(AUD + "/api/1/vehicles/" + vid + "/vehicle_data?endpoints=location_data", at))
    val ds = vd.getJSONObject("response").getJSONObject("drive_state")
    if (!ds.has("latitude") || !ds.has("longitude")) return null
    return Pair(ds.getDouble("latitude"), ds.getDouble("longitude"))
  }

  fun insert(sp: SharedPreferences, driveId: String, lat: Double, lng: Double) {
    val url = sp.getString("url", "") ?: ""
    val key = sp.getString("key", "") ?: ""
    val payload = JSONObject().put("drive_id", driveId).put("lat", lat).put("lng", lng).toString()
    val c = URL(url + "/rest/v1/positions").openConnection() as HttpURLConnection
    c.requestMethod = "POST"
    c.doOutput = true
    c.setRequestProperty("apikey", key)
    c.setRequestProperty("Authorization", "Bearer " + key)
    c.setRequestProperty("Content-Type", "application/json")
    c.outputStream.use { it.write(payload.toByteArray()) }
    val code = c.responseCode
    c.disconnect()
    if (code >= 300) throw RuntimeException("supabase " + code)
  }

  private fun get(u: String, token: String): String {
    val c = URL(u).openConnection() as HttpURLConnection
    c.connectTimeout = 15000
    c.readTimeout = 15000
    c.setRequestProperty("Authorization", "Bearer " + token)
    if (c.responseCode >= 300) throw RuntimeException(u + " -> " + c.responseCode)
    return c.inputStream.bufferedReader().readText()
  }

  private fun post(u: String, form: String, token: String?): String {
    val c = URL(u).openConnection() as HttpURLConnection
    c.requestMethod = "POST"
    c.doOutput = true
    c.connectTimeout = 15000
    c.readTimeout = 15000
    c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
    if (token != null) c.setRequestProperty("Authorization", "Bearer " + token)
    c.outputStream.use { it.write(form.toByteArray()) }
    if (c.responseCode >= 300) throw RuntimeException(u + " -> " + c.responseCode)
    return c.inputStream.bufferedReader().readText()
  }
}
EOF

cat > app/src/main/java/com/jh/drivelog/MainActivity.kt <<'EOF'
package com.jh.drivelog

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView

class MainActivity : Activity() {
  override fun onCreate(s: Bundle?) {
    super.onCreate(s)
    val sp = getSharedPreferences("cfg", Context.MODE_PRIVATE)
    val root = LinearLayout(this)
    root.orientation = LinearLayout.VERTICAL
    val pad = (16 * resources.displayMetrics.density).toInt()
    root.setPadding(pad, pad, pad, pad)

    val refresh = EditText(this)
    refresh.hint = "Tesla refresh token"
    refresh.setText(sp.getString("refresh", ""))
    val url = EditText(this)
    url.hint = "Supabase URL"
    url.setText(sp.getString("url", "https://rzdjebtjlejjskvjrdec.supabase.co"))
    val key = EditText(this)
    key.hint = "Supabase service_role key"
    key.setText(sp.getString("key", ""))

    val label = TextView(this)
    label.text = "차 블루투스 선택:"
    label.setPadding(0, pad, 0, 0)
    val spinner = Spinner(this)
    val names = ArrayList<String>()
    val addrs = ArrayList<String>()
    try {
      val ad = BluetoothAdapter.getDefaultAdapter()
      ad?.bondedDevices?.forEach { names.add(it.name + " (" + it.address + ")"); addrs.add(it.address) }
    } catch (e: Exception) {
    }
    if (names.isEmpty()) names.add("(페어링된 기기 없음/블루투스 켜기)")
    spinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, names)
    val savedDev = sp.getString("dev", "") ?: ""
    val idx = addrs.indexOf(savedDev)
    if (idx >= 0) spinner.setSelection(idx)

    val startBtn = Button(this)
    startBtn.text = "시작 / 저장"
    val testBtn = Button(this)
    testBtn.text = "지금 한번 기록 (테스트)"
    val status = TextView(this)
    status.setPadding(0, pad, 0, 0)
    status.text = "1) 토큰/키 입력  2) 차 블루투스 선택  3) 시작.\n이후 차에 타면 자동으로 기록됩니다."

    root.addView(refresh)
    root.addView(url)
    root.addView(key)
    root.addView(label)
    root.addView(spinner)
    root.addView(startBtn)
    root.addView(testBtn)
    root.addView(status)
    val sv = ScrollView(this)
    sv.addView(root)
    setContentView(sv)

    fun save() {
      val pos = spinner.selectedItemPosition
      val dev = if (pos >= 0 && pos < addrs.size) addrs[pos] else ""
      sp.edit()
        .putString("refresh", refresh.text.toString().trim())
        .putString("url", url.text.toString().trim())
        .putString("key", key.text.toString().trim())
        .putString("dev", dev)
        .apply()
    }

    startBtn.setOnClickListener {
      save()
      val i = Intent(this, LoggerService::class.java)
      if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
      status.text = "시작됨! 알림창에 'DriveLog 대기 중' 보이면 정상.\n이제 차에 타면 자동 기록됩니다."
    }

    testBtn.setOnClickListener {
      save()
      status.text = "테스트 실행 중..."
      Thread {
        val r = try {
          val at = Api.accessToken(sp)
          val vid = Api.vehicleId(at)
          val loc = Api.location(at, vid) ?: throw RuntimeException("위치 없음 (차 깨우기)")
          Api.insert(sp, "app-test", loc.first, loc.second)
          "테스트 성공! 저장됨: " + loc.first + ", " + loc.second
        } catch (e: Exception) {
          "에러: " + e.message
        }
        runOnUiThread { status.text = r }
      }.start()
    }
  }
}
EOF

cat > app/src/main/java/com/jh/drivelog/LoggerService.kt <<'EOF'
package com.jh.drivelog

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.IBinder

class LoggerService : Service() {
  private val ch = "drivelog"
  @Volatile private var driving = false
  private var worker: Thread? = null
  private var receiver: BroadcastReceiver? = null

  override fun onBind(i: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= 26) {
      nm.createNotificationChannel(NotificationChannel(ch, "DriveLog", NotificationManager.IMPORTANCE_LOW))
    }
    startForeground(1, notif("대기 중 (차 연결 기다리는 중)"))
    val f = IntentFilter()
    f.addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
    f.addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
    receiver = object : BroadcastReceiver() {
      override fun onReceive(c: Context?, i: Intent?) {
        if (i == null) return
        val dev = i.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
        val car = getSharedPreferences("cfg", Context.MODE_PRIVATE).getString("dev", "") ?: ""
        if (car.isEmpty() || dev.address != car) return
        if (i.action == BluetoothDevice.ACTION_ACL_CONNECTED) startDrive()
        else if (i.action == BluetoothDevice.ACTION_ACL_DISCONNECTED) stopDrive()
      }
    }
    registerReceiver(receiver, f)
  }

  override fun onStartCommand(i: Intent?, flags: Int, id: Int): Int = START_STICKY

  override fun onDestroy() {
    super.onDestroy()
    try { receiver?.let { unregisterReceiver(it) } } catch (e: Exception) {}
    driving = false
  }

  private fun notif(text: String): Notification {
    val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, ch) else Notification.Builder(this)
    return b.setContentTitle("DriveLog")
      .setContentText(text)
      .setSmallIcon(android.R.drawable.ic_menu_mylocation)
      .setOngoing(true)
      .build()
  }

  private fun update(text: String) {
    (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(1, notif(text))
  }

  private fun startDrive() {
    if (driving) return
    driving = true
    update("주행 기록 중...")
    val driveId = "drive-" + System.currentTimeMillis()
    worker = Thread {
      val sp = getSharedPreferences("cfg", Context.MODE_PRIVATE)
      try {
        val at = Api.accessToken(sp)
        val vid = Api.vehicleId(at)
        var count = 0
        while (driving) {
          try {
            val loc = Api.location(at, vid)
            if (loc != null) {
              Api.insert(sp, driveId, loc.first, loc.second)
              count++
              update("주행 기록 중... (" + count + "개 저장)")
            }
          } catch (e: Exception) {
          }
          var n = 0
          while (driving && n < 30) { Thread.sleep(1000); n++ }
        }
      } catch (e: Exception) {
        update("오류: " + e.message)
      }
    }
    worker?.start()
  }

  private fun stopDrive() {
    if (!driving) return
    driving = false
    update("대기 중 (차 연결 기다리는 중)")
  }
}
EOF

cat > app/src/main/java/com/jh/drivelog/BootReceiver.kt <<'EOF'
package com.jh.drivelog

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class BootReceiver : BroadcastReceiver() {
  override fun onReceive(c: Context, i: Intent) {
    val s = Intent(c, LoggerService::class.java)
    if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(s) else c.startService(s)
  }
}
EOF

echo "== accepting sdk licenses (insurance) =="
yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "platforms;android-34" "build-tools;34.0.0" >/dev/null 2>&1 || true

echo "== gradle wrapper + build =="
gradle wrapper --gradle-version 8.7 --distribution-type bin
./gradlew assembleDebug --no-daemon --stacktrace

mkdir -p out
cp app/build/outputs/apk/debug/app-debug.apk out/drivelog.apk
echo "== DONE: out/drivelog.apk =="
