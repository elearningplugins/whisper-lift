import Foundation

/** Settings kept out of the public source; the app reads them from Info.plist keys that the ignored config/MyQ.local.xcconfig fills in. */
public struct MyQConfiguration: Equatable, Sendable {
    public static let appCheckDebugTokenInfoKey = "MyQAppCheckDebugToken"

    public enum SetupError: Error, Equatable, Sendable, CustomStringConvertible {
        case missingAppCheckDebugToken
        case malformedAppCheckDebugToken

        public var description: String {
            switch self {
            case .missingAppCheckDebugToken: "MYQ_APP_CHECK_DEBUG_TOKEN is not set in config/MyQ.local.xcconfig."
            case .malformedAppCheckDebugToken: "MYQ_APP_CHECK_DEBUG_TOKEN in config/MyQ.local.xcconfig is not in the expected 8-4-4-4-12 hexadecimal form."
            }
        }
    }

    public let appCheckDebugToken: String

    public init(info: [String: Any]) throws {
        let raw = (info[Self.appCheckDebugTokenInfoKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An unexpanded $(NAME) means the xcconfig never defined the setting.
        guard !raw.isEmpty, !raw.hasPrefix("$(") else { throw SetupError.missingAppCheckDebugToken }
        guard raw.wholeMatch(of: /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/) != nil else {
            throw SetupError.malformedAppCheckDebugToken
        }
        appCheckDebugToken = raw
    }
}
