#!/bin/bash
set -e
mkdir -p app/src/main/assets app/src/main/java/com/anime/senki app/src/main/res/mipmap-xxxhdpi
cp index.html app/src/main/assets/index.html
if [ -f icon.png ]; then cp icon.png app/src/main/res/mipmap-xxxhdpi/ic_launcher.png; ICON='android:icon="@mipmap/ic_launcher"'; else ICON=''; fi

cat > settings.gradle <<'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "AnimeSenki"
include ':app'
EOF

cat > build.gradle <<'EOF'
plugins { id 'com.android.application' version '8.5.2' apply false }
EOF

cat > gradle.properties <<'EOF'
org.gradle.jvmargs=-Xmx3g
android.useAndroidX=false
EOF

cat > app/build.gradle <<'EOF'
plugins { id 'com.android.application' }
android {
    namespace 'com.anime.senki'
    compileSdk 34
    defaultConfig {
        applicationId 'com.anime.senki'
        minSdk 21
        targetSdk 34
        versionCode 1
        versionName '1.0'
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
}
EOF

cat > app/src/main/AndroidManifest.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="Anime Senki" $ICON android:hardwareAccelerated="true"
        android:theme="@android:style/Theme.NoTitleBar.Fullscreen">
        <activity android:name=".MainActivity" android:exported="true"
            android:screenOrientation="sensorLandscape"
            android:configChanges="orientation|screenSize|keyboardHidden|screenLayout|smallestScreenSize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

cat > app/src/main/java/com/anime/senki/MainActivity.java <<'EOF'
package com.anime.senki;

import android.app.Activity;
import android.os.Bundle;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.ValueCallback;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {
    private WebView web;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN, WindowManager.LayoutParams.FLAG_FULLSCREEN);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        web.setWebViewClient(new WebViewClient());
        setContentView(web);
        hideUi();
        web.loadUrl("file:///android_asset/index.html");
    }

    private void hideUi() {
        getWindow().getDecorView().setSystemUiVisibility(
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_FULLSCREEN
            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideUi();
    }

    @Override
    protected void onPause() {
        super.onPause();
        web.evaluateJavascript("if(typeof scene!=='undefined'&&scene==='play')scene='pause';", null);
        web.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
    }

    @Override
    public void onBackPressed() {
        web.evaluateJavascript(
            "(function(){if(typeof scene==='undefined'||scene==='menu')return 'exit';"
            + "if(scene==='play')scene='pause';else if(scene==='pause')scene='play';"
            + "else if(scene==='info')scene=infoFrom;else if(scene==='lobby')scene='menu';"
            + "return 'ok';})()",
            new ValueCallback<String>() {
                @Override
                public void onReceiveValue(String v) {
                    if (v != null && v.contains("exit")) finish();
                }
            });
    }
}
EOF
