import Foundation

/** Resolves the App Group shared by the app and widget extension from the Info.plist value that the build settings expand. */
public enum AppGroup {
    public static let infoPlistKey = "GarageTilesAppGroup"

    public enum ResolutionError: Error, Equatable {
        case missingIdentifier
        case containerUnavailable(identifier: String)
    }

    /** Returns the identifier only when it is a fully expanded App Group name. */
    public static func validatedIdentifier(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, trimmed.hasPrefix("group."), trimmed.count > "group.".count, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    public static func identifier(in bundle: Bundle = .main) -> String? {
        validatedIdentifier(bundle.object(forInfoDictionaryKey: infoPlistKey))
    }

    public static func counterStore(in bundle: Bundle = .main) throws -> CounterStore {
        guard let identifier = identifier(in: bundle) else { throw ResolutionError.missingIdentifier }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw ResolutionError.containerUnavailable(identifier: identifier)
        }
        return CounterStore(directory: container.appendingPathComponent("Spike", isDirectory: true))
    }
}
