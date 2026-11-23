package app.simbridge.android.shell;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;

import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Runs as the shell user (app_process, started through Shizuku). Connects to the local abstract
 * socket opened by the scrcpy server and copies the raw call audio to stdout, which the app reads
 * through the Shizuku process pipe. Keeping the socket inside the shell domain avoids SELinux
 * denials for app <-> shell unix sockets.
 */
public final class SocketCat {
    private SocketCat() {}

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("usage: SocketCat <abstract-socket-name>");
            System.exit(2);
        }
        LocalSocket socket = null;
        for (int i = 0; i < 150 && socket == null; i++) { // up to ~15 s for the server to start
            LocalSocket s = new LocalSocket();
            try {
                s.connect(new LocalSocketAddress(args[0], LocalSocketAddress.Namespace.ABSTRACT));
                socket = s;
            } catch (IOException e) {
                try { s.close(); } catch (IOException ignored) { }
                Thread.sleep(100);
            }
        }
        if (socket == null) {
            System.err.println("SocketCat: could not connect to " + args[0]);
            System.exit(3);
        }
        InputStream in = socket.getInputStream();
        OutputStream out = new FileOutputStream(FileDescriptor.out);
        byte[] buf = new byte[7680]; // 40 ms of 48 kHz stereo s16
        int n;
        while ((n = in.read(buf)) > 0) {
            out.write(buf, 0, n);
            out.flush();
        }
    }
}
