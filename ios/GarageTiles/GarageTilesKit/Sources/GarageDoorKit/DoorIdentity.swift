import Foundation

/** The stable identity of one door: its myQ account ID and serial, never its mutable display name. */
public struct DoorIdentity: Hashable, Codable, Sendable {
    public let accountID: String
    public let serial: String

    public init(accountID: String, serial: String) {
        self.accountID = accountID
        self.serial = serial
    }

    /** Length-prefixed by Unicode scalars, so no account ID or serial content can make two identities collide. */
    public var entityIdentifier: String {
        "\(accountID.unicodeScalars.count):\(accountID)\(serial)"
    }

    public init?(entityIdentifier: String) {
        guard let colon = entityIdentifier.firstIndex(of: ":") else { return nil }
        let prefix = entityIdentifier[..<colon]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isASCII), prefix.allSatisfy(\.isNumber), let length = Int(prefix), length > 0 else { return nil }
        let rest = entityIdentifier[entityIdentifier.index(after: colon)...].unicodeScalars
        guard rest.count > length else { return nil }
        let split = rest.index(rest.startIndex, offsetBy: length)
        self.init(accountID: String(rest[..<split]), serial: String(rest[split...]))
    }
}
