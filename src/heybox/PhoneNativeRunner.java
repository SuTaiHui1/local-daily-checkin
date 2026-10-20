import java.security.Permission;

/** Local native computation only; Python owns the single controlled HTTP call. */
public final class PhoneNativeRunner {
    @SuppressWarnings("removal")
    public static void main(String[] args) throws Exception {
        System.setSecurityManager(new SecurityManager() {
            @Override public void checkPermission(Permission p) { }
            @Override public void checkConnect(String h, int p) {
                throw new SecurityException("Native computation has no network permission");
            }
            @Override public void checkConnect(String h, int p, Object c) {
                throw new SecurityException("Native computation has no network permission");
            }
        });
        NativeSigner.main(args);
    }
}
