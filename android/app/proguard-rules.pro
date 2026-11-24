-keep class org.java_websocket.** { *; }
-dontwarn org.slf4j.**
-dontwarn javax.annotation.**

# Started by app_process as the shell user (developer-mode call audio)
-keep class app.simbridge.android.shell.SocketCat { public static void main(java.lang.String[]); }
# Shizuku.newProcess is called by reflection
-keep class rikka.shizuku.** { *; }
-keep class moe.shizuku.** { *; }

# Built-in wireless-debugging client
-keep class io.github.muntashirakon.adb.** { *; }
-keep class org.conscrypt.** { *; }
-keep class sun.security.** { *; }
-dontwarn org.conscrypt.**
-dontwarn sun.security.**
-dontwarn javax.naming.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
