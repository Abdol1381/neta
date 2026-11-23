-keep class org.java_websocket.** { *; }
-dontwarn org.slf4j.**
-dontwarn javax.annotation.**

# Started by app_process as the shell user (developer-mode call audio)
-keep class app.simbridge.android.shell.SocketCat { public static void main(java.lang.String[]); }
# Shizuku.newProcess is called by reflection
-keep class rikka.shizuku.** { *; }
-keep class moe.shizuku.** { *; }
