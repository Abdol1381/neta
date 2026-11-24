package app.simbridge.android.shell;

import android.content.Context;
import android.os.Build;

import androidx.annotation.NonNull;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.SecureRandom;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.Date;
import java.util.Random;

import io.github.muntashirakon.adb.AbsAdbConnectionManager;
import sun.security.x509.AlgorithmId;
import sun.security.x509.CertificateAlgorithmId;
import sun.security.x509.CertificateExtensions;
import sun.security.x509.CertificateIssuerName;
import sun.security.x509.CertificateSerialNumber;
import sun.security.x509.CertificateSubjectName;
import sun.security.x509.CertificateValidity;
import sun.security.x509.CertificateVersion;
import sun.security.x509.CertificateX509Key;
import sun.security.x509.KeyIdentifier;
import sun.security.x509.PrivateKeyUsageExtension;
import sun.security.x509.SubjectKeyIdentifierExtension;
import sun.security.x509.X500Name;
import sun.security.x509.X509CertImpl;
import sun.security.x509.X509CertInfo;

/**
 * Client for the phone's own adbd (Wireless debugging), so the app gets shell privileges without
 * Shizuku. The RSA key and self-signed certificate are created once and kept in the app's private
 * storage; pairing authorises them with adbd.
 */
public final class AdbManager extends AbsAdbConnectionManager {
    private static AdbManager instance;

    public static synchronized AdbManager get(Context context) throws Exception {
        if (instance == null) instance = new AdbManager(context.getApplicationContext());
        return instance;
    }

    private final PrivateKey privateKey;
    private final Certificate certificate;

    private AdbManager(Context context) throws Exception {
        setApi(Build.VERSION.SDK_INT);
        setHostAddress("127.0.0.1");
        File keyFile = new File(context.getFilesDir(), "adb_key.pk8");
        File certFile = new File(context.getFilesDir(), "adb_cert.der");
        PrivateKey key = null;
        Certificate cert = null;
        if (keyFile.exists() && certFile.exists()) {
            try {
                key = KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(read(keyFile)));
                try (InputStream in = new FileInputStream(certFile)) {
                    cert = CertificateFactory.getInstance("X.509").generateCertificate(in);
                }
            } catch (Exception e) {
                key = null;
                cert = null;
            }
        }
        if (key == null || cert == null) {
            KeyPairGenerator gen = KeyPairGenerator.getInstance("RSA");
            gen.initialize(2048, new SecureRandom());
            KeyPair pair = gen.generateKeyPair();
            PublicKey publicKey = pair.getPublic();
            key = pair.getPrivate();
            String algorithm = "SHA512withRSA";
            Date notBefore = new Date();
            Date notAfter = new Date(System.currentTimeMillis() + 3650L * 86400000L); // 10 years
            CertificateExtensions extensions = new CertificateExtensions();
            extensions.set("SubjectKeyIdentifier",
                    new SubjectKeyIdentifierExtension(new KeyIdentifier(publicKey).getIdentifier()));
            extensions.set("PrivateKeyUsage", new PrivateKeyUsageExtension(notBefore, notAfter));
            X500Name name = new X500Name("CN=SIMBridge");
            X509CertInfo info = new X509CertInfo();
            info.set("version", new CertificateVersion(2));
            info.set("serialNumber", new CertificateSerialNumber(new Random().nextInt() & Integer.MAX_VALUE));
            info.set("algorithmID", new CertificateAlgorithmId(AlgorithmId.get(algorithm)));
            info.set("subject", new CertificateSubjectName(name));
            info.set("key", new CertificateX509Key(publicKey));
            info.set("validity", new CertificateValidity(notBefore, notAfter));
            info.set("issuer", new CertificateIssuerName(name));
            info.set("extensions", extensions);
            X509CertImpl impl = new X509CertImpl(info);
            impl.sign(key, algorithm);
            cert = impl;
            write(keyFile, key.getEncoded());
            write(certFile, cert.getEncoded());
        }
        privateKey = key;
        certificate = cert;
    }

    @NonNull
    @Override
    protected PrivateKey getPrivateKey() {
        return privateKey;
    }

    @NonNull
    @Override
    protected Certificate getCertificate() {
        return certificate;
    }

    @NonNull
    @Override
    protected String getDeviceName() {
        return "SIMBridge";
    }

    private static byte[] read(File f) throws IOException {
        try (InputStream in = new FileInputStream(f)) {
            byte[] buf = new byte[(int) f.length()];
            int off = 0;
            while (off < buf.length) {
                int n = in.read(buf, off, buf.length - off);
                if (n < 0) break;
                off += n;
            }
            return buf;
        }
    }

    private static void write(File f, byte[] data) throws IOException {
        try (FileOutputStream out = new FileOutputStream(f)) {
            out.write(data);
        }
    }
}
