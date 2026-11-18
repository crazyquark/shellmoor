// Tether: fixed build info in place of upstream's SwiftTermBuildInfoPlugin, whose generator
// tool Xcode fails to find when building for the simulator.

/// Source-control information for this SwiftTerm build.
public enum SwiftTermBuildInfo {
    public static let branch: String? = nil
    public static let tag: String? = "v1.20.0"
    public static let commit: String? = nil
    public static let hasUncommittedChanges: Bool? = true
    public static let version: String = {
        let base = tag ?? commit.map { String($0.prefix(12)) } ?? "unknown"
        return hasUncommittedChanges == true ? "\(base)-modified" : base
    }()
}
