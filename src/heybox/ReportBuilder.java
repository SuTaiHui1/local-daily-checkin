import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.X509EncodedKeySpec;
import java.util.*;
import java.util.zip.*;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** Local mobile-report envelope; no HTTP, account, logging, or scheduler code. */
@SuppressWarnings("removal")
public final class ReportBuilder {
  record Report(String data, String key, String sid, String time, byte[] aesKey) {
    String json() { return "{\"data\":" + quote(data) + ",\"key\":" + quote(key)
      + ",\"sid\":" + quote(sid) + ",\"time\":" + quote(time) + "}"; }
  }
  static String quote(String s) {
    StringBuilder out = new StringBuilder("\"");
    for (char c : s.toCharArray()) {
      switch(c) {
        case '\\': out.append("\\\\"); break;
        case '"': out.append("\\\""); break;
        case '\n': out.append("\\n"); break;
        case '\r': out.append("\\r"); break;
        case '\t': out.append("\\t"); break;
        default: if(c < 32) out.append(String.format("\\u%04x", (int)c)); else out.append(c);
      }
    }
    return out.append('"').toString();
  }
  static String material(Properties p, String name) {
    return new String(Base64.getDecoder().decode(p.getProperty(name + "_b64")), StandardCharsets.UTF_8);
  }
  static byte[] gzip(String value) throws IOException {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try (GZIPOutputStream gzip = new GZIPOutputStream(out)) { gzip.write(value.getBytes(StandardCharsets.UTF_8)); }
    return out.toByteArray();
  }
  static String androidBase64(byte[] value) {
    if(value.length == 0) return "";
    return Base64.getMimeEncoder(76, new byte[]{'\n'}).encodeToString(value) + "\n";
  }
  static String md5(String value) throws Exception {
    return HexFormat.of().formatHex(MessageDigest.getInstance("MD5").digest(value.getBytes(StandardCharsets.UTF_8)));
  }
  static Report build(String payload, Properties p, PublicKey rsa, long timestamp) throws Exception {
    if (payload.isEmpty()) throw new IllegalArgumentException("Report payload must not be empty");
    String alphabet = material(p, "aes_alphabet");
    if (alphabet.length() != 95) throw new IllegalArgumentException("Unexpected App alphabet");
    SecureRandom random = new SecureRandom();
    StringBuilder randomKey = new StringBuilder();
    for (int i=0; i<16; i++) randomKey.append(alphabet.charAt(random.nextInt(alphabet.length())));
    byte[] aesKey = randomKey.toString().getBytes(StandardCharsets.UTF_8);
    Cipher aes = Cipher.getInstance("AES/CBC/PKCS5Padding"); // AES PKCS5 here is PKCS7 with 16-byte blocks.
    aes.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(aesKey, "AES"), new IvParameterSpec(material(p, "aes_iv").getBytes(StandardCharsets.UTF_8)));
    String data = androidBase64(aes.doFinal(gzip(payload)));
    Cipher wrapper = Cipher.getInstance("RSA/ECB/PKCS1Padding");
    wrapper.init(Cipher.ENCRYPT_MODE, rsa);
    String key = androidBase64(wrapper.doFinal(aesKey));
    String time = Long.toString(timestamp);
    return new Report(data, key, md5(key + time) + md5(data), time, aesKey);
  }
  static String recover(Report report, Properties p, byte[] aesKey) throws Exception {
    Cipher aes = Cipher.getInstance("AES/CBC/PKCS5Padding");
    aes.init(Cipher.DECRYPT_MODE, new SecretKeySpec(aesKey, "AES"), new IvParameterSpec(material(p, "aes_iv").getBytes(StandardCharsets.UTF_8)));
    byte[] compressed = aes.doFinal(Base64.getMimeDecoder().decode(report.data));
    try (GZIPInputStream gzip = new GZIPInputStream(new ByteArrayInputStream(compressed))) {
      return new String(gzip.readAllBytes(), StandardCharsets.UTF_8);
    }
  }
  static void check(boolean success, String description) {
    if (!success) throw new IllegalStateException(description);
  }
  static void selftest(Properties p, PublicKey actualKey, Path output) throws Exception {
    String[] payloads = {"{\"events\":[]}",
      "{\"events\":[{\"type\":\"4\",\"path\":\"/share/behavior/tap\",\"addition\":{\"src\":\"game_detail\",\"app_id\":\"0\",\"synthetic\":true}}]}",
      "{\"events\":[{\"synthetic\":true,\"text\":\"离线测试\\n不发送\"}]}"};
    int bits = ((RSAPublicKey)actualKey).getModulus().bitLength();
    for(String payload: payloads) {
      Report report = build(payload, p, actualKey, 1700000000L);
      check(payload.equals(recover(report, p, report.aesKey)), "AES/GZIP round trip failed");
      check(report.sid.equals(md5(report.key + report.time) + md5(report.data)), "SID check failed");
      check(Base64.getMimeDecoder().decode(report.key).length == (bits + 7) / 8, "RSA ciphertext size invalid");
      check(report.key.endsWith("\n") && report.data.endsWith("\n"), "Android Base64 terminator missing");
    }
    KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
    generator.initialize(bits);
    KeyPair syntheticKeys = generator.generateKeyPair();
    Report syntheticReport = build(payloads[1], p, syntheticKeys.getPublic(), 1700000000L);
    Cipher unwrap = Cipher.getInstance("RSA/ECB/PKCS1Padding");
    unwrap.init(Cipher.DECRYPT_MODE, syntheticKeys.getPrivate());
    byte[] recoveredKey = unwrap.doFinal(Base64.getMimeDecoder().decode(syntheticReport.key));
    check(payloads[1].equals(recover(syntheticReport, p, recoveredKey)), "Synthetic RSA/AES/GZIP round trip failed");
    String summary = "{\"status\":\"passed\",\"scope\":\"offline-synthetic-only\","
      + "\"actualPublicKeyEnvelopeCases\":3,\"aesGzipRoundTripCases\":3,\"syntheticRsaFullRoundTrip\":true,"
      + "\"sidAndAndroidBase64Verified\":true,\"actualServerPrivateKeyDecryptionTested\":false,"
      + "\"businessRequests\":0,\"serverAcceptanceVerified\":false,\"accountDataUsed\":false}";
    Files.writeString(output, summary + "\n", StandardCharsets.UTF_8);
    System.out.println(summary);
  }
  public static void main(String[] args) throws Exception {
    System.setSecurityManager(new SecurityManager() {
      @Override public void checkPermission(Permission p) {}
      @Override public void checkConnect(String host, int port) { throw new SecurityException("Network disabled"); }
      @Override public void checkListen(int port) { throw new SecurityException("Network disabled"); }
      @Override public void checkAccept(String host, int port) { throw new SecurityException("Network disabled"); }
    });
    if (args.length < 4) throw new IllegalArgumentException("selftest material key output | build material key input output [timestamp]");
    Properties p = new Properties();
    try (InputStream in = Files.newInputStream(Path.of(args[1]))) { p.load(in); }
    PublicKey key = KeyFactory.getInstance("RSA").generatePublic(new X509EncodedKeySpec(Files.readAllBytes(Path.of(args[2]))));
    if(args[0].equals("selftest")) selftest(p, key, Path.of(args[3]));
    else if(args[0].equals("build") && args.length >= 5) {
      long timestamp = args.length > 5 ? Long.parseLong(args[5]) : System.currentTimeMillis()/1000;
      Report report = build(Files.readString(Path.of(args[3]), StandardCharsets.UTF_8), p, key, timestamp);
      Files.writeString(Path.of(args[4]), report.json() + "\n", StandardCharsets.UTF_8);
      Arrays.fill(report.aesKey, (byte)0);
      System.out.println("Report envelope written locally; no payload or key printed.");
    } else throw new IllegalArgumentException("Unknown mode");
  }
}
