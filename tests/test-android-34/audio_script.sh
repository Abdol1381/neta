CLASSPATH=/data/local/tmp/simbridge-scrcpy.jar app_process / com.genymobile.scrcpy.Server 3.3.4 scid=1a2b3c4d log_level=warn video=false audio=true control=false audio_source=voice-call-downlink audio_codec=raw tunnel_forward=true raw_stream=true cleanup=false </dev/null >/dev/null 2>/data/local/tmp/simbridge-audio.log &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT INT TERM HUP
CLASSPATH=/data/app/~~BcuCF9L3wnhxwHhtygjqRQ==/app.simbridge.android-fWZold2ul6fq6_FxXxRFMA==/base.apk app_process / app.simbridge.android.shell.SocketCat scrcpy_1a2b3c4d
