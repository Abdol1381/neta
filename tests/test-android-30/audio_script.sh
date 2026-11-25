CLASSPATH=/data/local/tmp/simbridge-scrcpy.jar app_process / com.genymobile.scrcpy.Server 3.3.4 scid=1a2b3c4d log_level=warn video=false audio=true control=false audio_source=voice-call-downlink audio_codec=raw tunnel_forward=true raw_stream=true cleanup=false </dev/null >/dev/null 2>/data/local/tmp/simbridge-audio.log &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT INT TERM HUP
CLASSPATH=/data/app/~~G9wzfOZMTXBgg6ZFSxRW2g==/app.simbridge.android-BO1fDTkoQWGUN7DaugNO0g==/base.apk app_process / app.simbridge.android.shell.SocketCat scrcpy_1a2b3c4d
