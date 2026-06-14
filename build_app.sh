#!/usr/bin/env bash
set -e
echo "== generating android project =="
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
    targetSdk 34
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
  <application
      android:label="DriveLog"
      android:theme="@android:style/Theme.Material.Light.DarkActionBar">
    <activity android:name=".MainActivity" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
  </application>
</manifest>
EOF

cat > app/src/main/java/com/jh/drivelog/MainActivity.kt <<'EOF'
package com.jh.drivelog

import android.app.Activity
import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

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
    val btn = Button(this)
    btn.text = "기록 테스트"
    val log = TextView(this)
    log.setPadding(0, pad, 0, 0)

    root.addView(refresh)
    root.addView(url)
    root.addView(key)
    root.addView(btn)
    root.addView(log)
    val sv = ScrollView(this)
    sv.addView(root)
    setContentView(sv)

    btn.setOnClickListener {
      sp.edit()
        .putString("refresh", refresh.text.toString().trim())
        .putString("url", url.text.toString().trim())
        .putString("key", key.text.toString().trim())
        .apply()
      log.text = "실행 중..."
      Thread {
        val r = try { runOnce(sp) } catch (e: Exception) { "에러: " + e.message }
        runOnUiThread { log.text = r }
      }.start()
    }
  }

  private fun runOnce(sp: SharedPreferences): String {
    val cid = "b60e10ca-556c-44bd-98c6-19dbb43c7bb3"
    val aud = "https://fleet-api.prd.na.vn.cloud.tesla.com"
    val refresh = sp.getString("refresh", "") ?: ""
    val body = "grant_type=refresh_token&client_id=" + cid + "&refresh_token=" + refresh
    val tok = JSONObject(post("https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token", body, null))
    val at = tok.getString("access_token")
    val newRefresh = tok.optString("refresh_token", refresh)
    sp.edit().putString("refresh", newRefresh).apply()
    val resp = JSONObject(get(aud + "/api/1/vehicles", at)).getJSONArray("response")
    if (resp.length() == 0) return "차량 없음"
    val v = resp.getJSONObject(0)
    val vid = v.getString("id")
    val state = v.optString("state")
    val vd = JSONObject(get(aud + "/api/1/vehicles/" + vid + "/vehicle_data?endpoints=location_data", at))
    val ds = vd.getJSONObject("response").getJSONObject("drive_state")
    val lat = ds.getDouble("latitude")
    val lng = ds.getDouble("longitude")
    insert(sp.getString("url", "") ?: "", sp.getString("key", "") ?: "", lat, lng)
    return "성공! 상태=" + state + "\n위치=" + lat + ", " + lng + "\nSupabase 저장 완료"
  }

  private fun insert(url: String, key: String, lat: Double, lng: Double) {
    val payload = JSONObject().put("drive_id", "app-test").put("lat", lat).put("lng", lng).toString()
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
    c.setRequestProperty("Authorization", "Bearer " + token)
    if (c.responseCode >= 300) throw RuntimeException(u + " -> " + c.responseCode)
    return c.inputStream.bufferedReader().readText()
  }

  private fun post(u: String, form: String, token: String?): String {
    val c = URL(u).openConnection() as HttpURLConnection
    c.requestMethod = "POST"
    c.doOutput = true
    c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
    if (token != null) c.setRequestProperty("Authorization", "Bearer " + token)
    c.outputStream.use { it.write(form.toByteArray()) }
    if (c.responseCode >= 300) throw RuntimeException(u + " -> " + c.responseCode)
    return c.inputStream.bufferedReader().readText()
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
