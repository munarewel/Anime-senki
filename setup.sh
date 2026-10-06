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
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <application android:label="Anime Senki" $ICON android:hardwareAccelerated="true" android:usesCleartextTraffic="true"
        android:theme="@android:style/Theme.NoTitleBar.Fullscreen">
        <activity android:name=".MainActivity" android:exported="true"
            android:screenOrientation="sensorLandscape"
            android:windowSoftInputMode="adjustPan"
            android:configChanges="orientation|screenSize|keyboardHidden|screenLayout|smallestScreenSize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

cat > app/src/main/java/com/anime/senki/Relay.java <<'EOF'
package com.anime.senki;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;

/** Tiny WebSocket relay: one "host" connection + many clients. No external libraries. */
public class Relay {
    private final int port;
    private ServerSocket server;
    private volatile boolean running = false;
    private Conn host = null;
    private final Map<Integer, Conn> clients = new ConcurrentHashMap<>();
    private int nextId = 1;

    public Relay(int port) { this.port = port; }

    public synchronized boolean start() {
        if (running) return true;
        try {
            server = new ServerSocket();
            server.setReuseAddress(true);
            server.bind(new InetSocketAddress(port));
            running = true;
            Thread t = new Thread(this::acceptLoop, "relay-accept");
            t.setDaemon(true);
            t.start();
            return true;
        } catch (IOException e) { return false; }
    }

    public boolean isRunning() { return running; }

    private void acceptLoop() {
        while (running) {
            try {
                Socket s = server.accept();
                s.setTcpNoDelay(true);
                Conn c = new Conn(s);
                Thread t = new Thread(c::run, "relay-conn");
                t.setDaemon(true);
                t.start();
            } catch (IOException e) { if (!running) break; }
        }
    }

    private synchronized void onMessage(Conn c, String msg) {
        if (c.role == 0) {
            if (msg.equals("HOST") && host == null) { c.role = 1; host = c; c.send("OK"); return; }
            c.role = 2; c.id = nextId++; clients.put(c.id, c);
            if (host != null) host.send("J" + c.id);
        }
        if (c.role == 1) {
            if (msg.startsWith("B|")) { String p = msg.substring(2); for (Conn k : clients.values()) k.send(p); }
            else if (msg.startsWith("T")) { int bar = msg.indexOf('|'); if (bar > 1) { try { Conn k = clients.get(Integer.parseInt(msg.substring(1, bar))); if (k != null) k.send(msg.substring(bar + 1)); } catch (NumberFormatException ignored) {} } }
        } else if (c.role == 2) {
            if (host != null) host.send("C" + c.id + "|" + msg);
        }
    }

    private synchronized void onClose(Conn c) {
        if (c.role == 1 && host == c) { host = null; for (Conn k : clients.values()) k.close(); clients.clear(); }
        else if (c.role == 2) { clients.remove(c.id); if (host != null) host.send("L" + c.id); }
    }

    private class Conn {
        final Socket s; InputStream in; OutputStream out; int role = 0; int id = 0;
        final LinkedBlockingDeque<String> q = new LinkedBlockingDeque<>();
        volatile boolean open = true;
        Conn(Socket s) { this.s = s; }

        void send(String m) { if (!open) return; if (q.size() > 40) q.pollFirst(); q.offer(m); }
        void close() { open = false; try { s.close(); } catch (IOException ignored) {} q.offer(""); }

        void run() {
            try {
                in = new BufferedInputStream(s.getInputStream());
                out = new BufferedOutputStream(s.getOutputStream());
                if (!handshake()) { s.close(); return; }
                Thread w = new Thread(this::writeLoop, "relay-write"); w.setDaemon(true); w.start();
                ByteArrayOutputStream frag = new ByteArrayOutputStream();
                while (open) {
                    int b0 = in.read(); if (b0 < 0) break;
                    int b1 = in.read(); if (b1 < 0) break;
                    boolean fin = (b0 & 0x80) != 0; int op = b0 & 0x0F; boolean masked = (b1 & 0x80) != 0;
                    long len = b1 & 0x7F;
                    if (len == 126) len = ((in.read() & 0xFF) << 8) | (in.read() & 0xFF);
                    else if (len == 127) { len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | (in.read() & 0xFF); }
                    byte[] mask = new byte[4];
                    if (masked) readFully(mask);
                    if (len > 8_000_000) break;
                    byte[] data = new byte[(int) len];
                    readFully(data);
                    if (masked) for (int i = 0; i < data.length; i++) data[i] ^= mask[i & 3];
                    if (op == 8) break;
                    if (op == 9) { sendFrame(10, data); continue; }
                    if (op == 10) continue;
                    if (op == 1 || op == 2 || op == 0) {
                        frag.write(data);
                        if (fin) { String m = new String(frag.toByteArray(), StandardCharsets.UTF_8); frag.reset(); onMessage(this, m); }
                    }
                }
            } catch (IOException ignored) {
            } finally { open = false; q.offer(""); try { s.close(); } catch (IOException ignored) {} onClose(this); }
        }

        void writeLoop() {
            try {
                while (open) {
                    String m = q.take();
                    if (!open) break;
                    sendFrame(1, m.getBytes(StandardCharsets.UTF_8));
                }
            } catch (Exception ignored) { open = false; try { s.close(); } catch (IOException e) {} }
        }

        void readFully(byte[] b) throws IOException { int o = 0; while (o < b.length) { int r = in.read(b, o, b.length - o); if (r < 0) throw new EOFException(); o += r; } }

        synchronized void sendFrame(int op, byte[] data) throws IOException {
            out.write(0x80 | op);
            int n = data.length;
            if (n < 126) out.write(n);
            else if (n < 65536) { out.write(126); out.write((n >> 8) & 0xFF); out.write(n & 0xFF); }
            else { out.write(127); for (int i = 7; i >= 0; i--) out.write((int) (((long) n >> (8 * i)) & 0xFF)); }
            out.write(data); out.flush();
        }

        boolean handshake() throws IOException {
            StringBuilder sb = new StringBuilder(); String key = null;
            while (true) {
                String line = readLine(); if (line == null) return false;
                if (line.isEmpty()) break;
                int c = line.indexOf(':');
                if (c > 0 && line.substring(0, c).trim().equalsIgnoreCase("Sec-WebSocket-Key")) key = line.substring(c + 1).trim();
            }
            if (key == null) {
                String body = "Anime Senki relay";
                out.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " + body.length() + "\r\nConnection: close\r\n\r\n" + body).getBytes(StandardCharsets.UTF_8));
                out.flush(); return false;
            }
            String acc;
            try {
                MessageDigest md = MessageDigest.getInstance("SHA-1");
                acc = b64(md.digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").getBytes(StandardCharsets.UTF_8)));
            } catch (Exception e) { return false; }
            out.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + acc + "\r\n\r\n").getBytes(StandardCharsets.UTF_8));
            out.flush();
            return true;
        }

        String readLine() throws IOException {
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            while (true) { int c = in.read(); if (c < 0) return null; if (c == '\n') break; if (c != '\r') b.write(c); if (b.size() > 8192) return null; }
            return new String(b.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    static String b64(byte[] d) {
        final String T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < d.length; i += 3) {
            int b = (d[i] & 0xFF) << 16 | (i + 1 < d.length ? (d[i + 1] & 0xFF) << 8 : 0) | (i + 2 < d.length ? (d[i + 2] & 0xFF) : 0);
            sb.append(T.charAt((b >> 18) & 63)).append(T.charAt((b >> 12) & 63));
            sb.append(i + 1 < d.length ? T.charAt((b >> 6) & 63) : '=');
            sb.append(i + 2 < d.length ? T.charAt(b & 63) : '=');
        }
        return sb.toString();
    }

    public static void main(String[] a) throws Exception {
        Relay r = new Relay(a.length > 0 ? Integer.parseInt(a[0]) : 8765);
        System.out.println("start=" + r.start());
        Thread.sleep(Long.MAX_VALUE);
    }
}

EOF

cat > app/src/main/java/com/anime/senki/MainActivity.java <<'EOF'
package com.anime.senki;

import android.app.Activity;
import android.content.Context;
import android.net.DhcpInfo;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.Collections;

public class MainActivity extends Activity {
    private WebView web;
    private static Relay relay;

    public class Bridge {
        @JavascriptInterface
        public boolean startServer() {
            if (relay == null) relay = new Relay(8765);
            return relay.start();
        }
        @JavascriptInterface
        public String getIPs() {
            StringBuilder sb = new StringBuilder();
            try {
                for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                    if (!ni.isUp() || ni.isLoopback()) continue;
                    for (InetAddress a : Collections.list(ni.getInetAddresses())) {
                        if (a instanceof Inet4Address && !a.isLoopbackAddress()) {
                            String ip = a.getHostAddress();
                            String name = ni.getName();
                            boolean pref = name.startsWith("ap") || name.startsWith("swlan") || name.startsWith("wlan") || ip.startsWith("192.168.");
                            if (pref) sb.insert(0, ip + ","); else sb.append(ip).append(",");
                        }
                    }
                }
            } catch (Exception ignored) {}
            String r = sb.toString();
            return r.endsWith(",") ? r.substring(0, r.length() - 1) : r;
        }
        @JavascriptInterface
        public String getGateway() {
            try {
                WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
                DhcpInfo d = wm.getDhcpInfo();
                if (d == null || d.gateway == 0) return "";
                int g = d.gateway;
                return (g & 0xFF) + "." + ((g >> 8) & 0xFF) + "." + ((g >> 16) & 0xFF) + "." + ((g >> 24) & 0xFF);
            } catch (Exception e) { return ""; }
        }
    }

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
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Bridge(), "Android");
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
        web.evaluateJavascript("if(typeof scene!=='undefined'&&scene==='play'&&MODE!=='coop')scene='pause';", null);
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
            + "if(MODE==='coop'&&scene==='play'){NET.menuOpen=!NET.menuOpen;return 'ok';}"
            + "if(scene==='play')scene='pause';else if(scene==='pause')scene='play';"
            + "else if(scene==='info')scene=infoFrom;else if(scene==='lobby'){if(MODE==='coop'){netLeave();scene='mp';}else scene='menu';}"
            + "else if(scene==='mp'){netLeave();scene='menu';}"
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
