import Foundation

/** Unsupported myQ client metadata and hosts in one place; values are pinned from cnberry/gatectl 47ef70d src/gatectl/constants.py (MIT). */
public enum MyQMetadata {
    public static let identityHost = "partner-identity.myq-cloud.com"
    public static let accountsHost = "accounts.myq-cloud.com"
    public static let devicesHost = "devices.myq-cloud.com"
    public static let commandsHost = "account-devices-gdo.myq-cloud.com"
    // myQ requires a Firebase App Check token for the sign-in code exchange; gatectl's security review covered this host.
    public static let appCheckHost = "firebaseappcheck.googleapis.com"
    public static let allowedHosts: Set<String> = [identityHost, accountsHost, devicesHost, commandsHost, appCheckHost]

    public static let oauthClientID = "ANDROID_CGI_MYQ"
    public static let oauthRedirectURI = "com.myqops://android"
    public static let oauthScope = "MyQ_Residential offline_access"
    public static let appVersion = "5.243.1.73243"
    public static let userAgent = "sdk_gphone_x86/Android 11"
    public static let brandID = "1"

    // Distributed client metadata, not personal credentials, from gatectl 47ef70d constants.py; myQ can rotate it at any time. The App Check debug token is local configuration, see MyQConfiguration.
    public static let firebaseProjectID = "myq-transition-test"
    public static let firebaseAppID = "1:169499880894:android:120796f2b5e44ca7"
    public static let firebaseAPIKey = "AIzaSyDYwdJBRp6H3UhrCp5LGY8XTPJG7hTeCgw" // gitleaks:allow public myQ Android client metadata reviewed in docs/gatectl-security-review.md
    public static let androidPackage = "com.chamberlain.android.liftmaster.myq"
    public static let androidCertSHA1 = "da2bda70ee8a9062d076babe65924caf9a8b98e9"

    /** True only for HTTPS on the default port to one of the four documented myQ hosts or the Firebase App Check host used at sign-in, without user info. */
    public static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https"
            && components.user == nil
            && components.password == nil
            && (components.port == nil || components.port == 443)
            && allowedHosts.contains(components.host?.lowercased() ?? "")
    }

    static func url(host: String, path: String) -> URL {
        URL(string: "https://\(host)\(path)")!
    }

    // Unreserved characters only, so slashes, spaces and form delimiters in IDs are always escaped.
    static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        allowed = allowed.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func commonHeaders() -> [String: String] {
        ["Accept": "application/json", "App-Version": appVersion, "BrandId": brandID, "User-Agent": userAgent]
    }
}
