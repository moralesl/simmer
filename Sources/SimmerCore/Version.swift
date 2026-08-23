/// The one version string. The CLI, the app and the bundle's Info.plist all
/// read from here (the Makefile extracts it for the plist) — three hand-kept
/// copies is how versions drift.
public enum SimmerVersion {
    public static let string = "1.0.0-dev"
}
