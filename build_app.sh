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
    versionCode 3
    versionName "3.0"
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
  // 한 번의 콜로 받을 데이터 묶음 (콜 수는 1개 그대로 = 비용 동일)
  private const val EP = "location_data;drive_state;charge_state;vehicle_state;climate_state"

  class Sample(
    val lat: Double, val lng: Double,
    val speed: Double?, val heading: Double?, val shift: String?, val power: Double?,
    val battery: Int?, val battRange: Double?, val odometer: Double?, val outTemp: Double?,
    val raw: String
  )

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

  // 차량 데이터 한 방에 받아 파싱. 위치 없으면(차 잠듦 등) null.
  fun sample(at: String, vid: String): Sample? {
    val u = AUD + "/api/1/vehicles/" + vid + "/vehicle_data?endpoints=" + EP.replace(";", "%3B")
    val resp = JSONObject(get(u, at)).getJSONObject("response")
    val ds = resp.optJSONObject("drive_state") ?: return null
    if (!ds.has("latitude") || ds.isNull("latitude") || !ds.has("longitude") || ds.isNull("longitude")) return null
    val cs = resp.optJSONObject("charge_state") ?: JSONObject()
    val vs = resp.optJSONObject("vehicle_state") ?: JSONObject()
    val cl = resp.optJSONObject("climate_state") ?: JSONObject()
    return Sample(
      ds.getDouble("latitude"), ds.getDouble("longitude"),
      dbl(ds, "speed"), dbl(ds, "heading"), str(ds, "shift_state"), dbl(ds, "power"),
      intv(cs, "battery_level"), dbl(cs, "battery_range"),
      dbl(vs, "odometer"), dbl(cl, "outside_temp"),
      resp.toString()
    )
  }

  // Supabase에 보낼 JSON 한 줄 생성 (raw에 응답 통째 저장)
  fun payload(driveId: String, s: Sample): String {
    val o = JSONObject()
    o.put("drive_id", driveId).put("lat", s.lat).put("lng", s.lng)
    if (s.speed != null) o.put("speed", s.speed)
    if (s.heading != null) o.put("heading", s.heading)
    if (s.shift != null) o.put("shift_state", s.shift)
    if (s.power != null) o.put("power", s.power)
    if (s.battery != null) o.put("battery", s.battery)
    if (s.battRange != null) o.put("batt_range", s.battRange)
    if (s.odometer != null) o.put("odometer", s.odometer)
    if (s.outTemp != null) o.put("out_temp", s.outTemp)
    o.put("raw", JSONObject(s.raw))
    return o.toString()
  }

  // 미리 만든 payload 한 줄을 전송. 성공 여부 반환(큐 재전송용).
  fun push(sp: SharedPreferences, payload: String): Boolean {
    val url = sp.getString("url", "") ?: ""
    val key = sp.getString("key", "") ?: ""
    val c = URL(url + "/rest/v1/positions").openConnection() as HttpURLConnection
    c.requestMethod = "POST"
    c.doOutput = true
    c.connectTimeout = 15000
    c.readTimeout = 15000
    c.setRequestProperty("apikey", key)
    c.setRequestProperty("Authorization", "Bearer " + key)
    c.setRequestProperty("Content-Type", "application/json")
    c.outputStream.use { it.write(payload.toByteArray()) }
    val code = c.responseCode
    c.disconnect()
    return code in 200..299
  }

  private fun dbl(o: JSONObject, k: String): Double? = if (o.has(k) && !o.isNull(k)) o.optDouble(k) else null
  private fun intv(o: JSONObject, k: String): Int? = if (o.has(k) && !o.isNull(k)) o.optInt(k) else null
  private fun str(o: JSONObject, k: String): String? = if (o.has(k) && !o.isNull(k)) o.optString(k) else null

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
import android.text.InputType
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
    val interval = EditText(this)
    interval.hint = "기록 간격(초) — 기본 30"
    interval.inputType = InputType.TYPE_CLASS_NUMBER
    interval.setText(sp.getInt("interval", 30).toString())

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
    root.addView(interval)
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
      var iv = interval.text.toString().trim().toIntOrNull() ?: 30
      if (iv < 10) iv = 10
      sp.edit()
        .putString("refresh", refresh.text.toString().trim())
        .putString("url", url.text.toString().trim())
        .putString("key", key.text.toString().trim())
        .putString("dev", dev)
        .putInt("interval", iv)
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
          val smp = Api.sample(at, vid) ?: throw RuntimeException("위치 없음 (차 깨우기)")
          val ok = Api.push(sp, Api.payload("app-test", smp))
          if (!ok) throw RuntimeException("Supabase 저장 실패")
          var msg = "테스트 성공! " + smp.lat + ", " + smp.lng
          if (smp.speed != null) msg += " · " + smp.speed + "mph"
          if (smp.battery != null) msg += " · 배터리 " + smp.battery + "%"
          if (smp.shift != null) msg += " · " + smp.shift
          msg
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
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.os.Build
import android.os.IBinder
import java.io.File

class LoggerService : Service() {
  private val ch = "drivelog"
  @Volatile private var driving = false
  @Volatile private var alive = true
  private var worker: Thread? = null
  private var hb: Thread? = null
  private var receiver: BroadcastReceiver? = null

  override fun onBind(i: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= 26) {
      nm.createNotificationChannel(NotificationChannel(ch, "DriveLog", NotificationManager.IMPORTANCE_MIN))
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
    startHeartbeat()
  }

  // 30초마다 차 BT 연결 상태를 직접 확인 → 연결 이벤트를 놓쳐도 자동으로 기록 시작/종료
  private fun carConnected(): Boolean {
    val car = getSharedPreferences("cfg", Context.MODE_PRIVATE).getString("dev", "") ?: ""
    if (car.isEmpty()) return false
    return try {
      val ad = BluetoothAdapter.getDefaultAdapter() ?: return false
      val dev = ad.bondedDevices?.firstOrNull { it.address == car } ?: return false
      val m = dev.javaClass.getMethod("isConnected")
      (m.invoke(dev) as Boolean)
    } catch (e: Exception) { false }
  }

  private fun startHeartbeat() {
    if (hb != null) return
    hb = Thread {
      while (alive) {
        try {
          val c = carConnected()
          if (c && !driving) startDrive()
          else if (!c && driving) stopDrive()
        } catch (e: Exception) {}
        var n = 0
        while (alive && n < 30) { try { Thread.sleep(1000) } catch (e: Exception) { break }; n++ }
      }
    }
    hb?.start()
  }

  override fun onStartCommand(i: Intent?, flags: Int, id: Int): Int = START_STICKY

  override fun onDestroy() {
    super.onDestroy()
    alive = false
    try { receiver?.let { unregisterReceiver(it) } } catch (e: Exception) {}
    driving = false
  }

  private fun notif(text: String): Notification {
    val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, ch) else Notification.Builder(this)
    return b.setContentTitle("DriveLog")
      .setContentText(text)
      .setSmallIcon(android.R.drawable.ic_menu_mylocation)
      .setOngoing(true)
      .setVisibility(Notification.VISIBILITY_SECRET)
      .setPriority(Notification.PRIORITY_MIN)
      .build()
  }

  private fun update(text: String) {
    (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(1, notif(text))
  }

  // ===== 오프라인 큐 (전송 실패한 점을 폰에 쌓아뒀다 재전송) =====
  private fun enqueue(line: String) {
    try { openFileOutput("queue.txt", Context.MODE_APPEND).use { it.write((line + "\n").toByteArray()) } } catch (e: Exception) {}
  }

  private fun queueSize(): Int {
    return try { File(filesDir, "queue.txt").readLines().count { it.isNotBlank() } } catch (e: Exception) { 0 }
  }

  private fun flushQueue(sp: SharedPreferences) {
    val f = File(filesDir, "queue.txt")
    if (!f.exists()) return
    val lines = try { f.readLines() } catch (e: Exception) { return }
    if (lines.isEmpty()) { try { f.delete() } catch (e: Exception) {}; return }
    val remain = ArrayList<String>()
    for (ln in lines) {
      if (ln.isBlank()) continue
      val ok = try { Api.push(sp, ln) } catch (e: Exception) { false }
      if (!ok) remain.add(ln)
    }
    try {
      if (remain.isEmpty()) f.delete()
      else f.writeText(remain.joinToString("\n") + "\n")
    } catch (e: Exception) {}
  }

  private fun startDrive() {
    if (driving) return
    driving = true
    update("주행 기록 중...")
    val driveId = "drive-" + System.currentTimeMillis()
    worker = Thread {
      val sp = getSharedPreferences("cfg", Context.MODE_PRIVATE)
      var iv = sp.getInt("interval", 30)
      if (iv < 10) iv = 10
      try {
        val at = Api.accessToken(sp)
        val vid = Api.vehicleId(at)
        var count = 0
        while (driving) {
          try {
            val smp = Api.sample(at, vid)
            if (smp != null) {
              val pl = Api.payload(driveId, smp)
              val ok = try { Api.push(sp, pl) } catch (e: Exception) { false }
              if (ok) {
                count++
                update("주행 기록 중... (" + count + "개 저장)")
              } else {
                enqueue(pl)
                update("주행 기록 중... (" + count + "개, 대기 " + queueSize() + ")")
              }
            }
          } catch (e: Exception) {
          }
          try { flushQueue(sp) } catch (e: Exception) {}
          var n = 0
          while (driving && n < iv) { Thread.sleep(1000); n++ }
        }
        try { flushQueue(sp) } catch (e: Exception) {}
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
