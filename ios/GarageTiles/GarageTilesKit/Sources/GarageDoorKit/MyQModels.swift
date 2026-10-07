import Foundation

/** Errors from parsing and talking to myQ; none carries a response body, token or header. */
public enum MyQError: Error, Equatable, Sendable {
    case malformedResponse
    case transport
    case invalidGrant
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int)
}

public struct MyQAccount: Hashable, Codable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /** Parses the accounts endpoint's `{"accounts": [...]}` payload; every account needs a non-empty ID. */
    public static func parseAccounts(_ data: Data) throws -> [MyQAccount] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = root["accounts"] as? [Any] else {
            throw MyQError.malformedResponse
        }
        return try raw.map { item in
            guard let object = item as? [String: Any], let id = object["id"] as? String, !id.isEmpty else { throw MyQError.malformedResponse }
            return MyQAccount(id: id, name: (object["name"] as? String) ?? id)
        }
    }
}

/** One device from myQ's device list with the fields the safety policy needs; wrong-typed flags are nil, never false. */
public struct DoorDevice: Hashable, Codable, Sendable {
    public let identity: DoorIdentity
    public let accountName: String
    public let name: String
    public let family: String
    public let state: DoorState
    public let online: Bool?
    public let unattendedOpenAllowed: Bool?
    public let unattendedCloseAllowed: Bool?
    public let vacationMode: Bool?
    public let activeFaults: [String]
    public let lastServerUpdate: Date?
    /** Safety fields myQ sent in an unexpected shape; any entry blocks commands, while an absent field only means the opener does not report it. */
    public let unreadableSafetyFields: [String]

    public init(
        identity: DoorIdentity, accountName: String, name: String, family: String, state: DoorState, online: Bool?,
        unattendedOpenAllowed: Bool?, unattendedCloseAllowed: Bool?, vacationMode: Bool?, activeFaults: [String], lastServerUpdate: Date?,
        unreadableSafetyFields: [String] = []
    ) {
        self.identity = identity
        self.accountName = accountName
        self.name = name
        self.family = family
        self.state = state
        self.online = online
        self.unattendedOpenAllowed = unattendedOpenAllowed
        self.unattendedCloseAllowed = unattendedCloseAllowed
        self.vacationMode = vacationMode
        self.activeFaults = activeFaults
        self.lastServerUpdate = lastServerUpdate
        self.unreadableSafetyFields = unreadableSafetyFields
    }

    public var isGarageDoor: Bool { family == "garagedoor" }

    enum CodingKeys: String, CodingKey {
        case identity, accountName, name, family, state, online, unattendedOpenAllowed, unattendedCloseAllowed, vacationMode, activeFaults
        case lastServerUpdate, unreadableSafetyFields
    }

    /** Decodes snapshots written before unreadableSafetyFields existed as having none, so an upgrade never turns stored data into a permanent refusal. */
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(DoorIdentity.self, forKey: .identity)
        accountName = try container.decode(String.self, forKey: .accountName)
        name = try container.decode(String.self, forKey: .name)
        family = try container.decode(String.self, forKey: .family)
        state = try container.decode(DoorState.self, forKey: .state)
        online = try container.decodeIfPresent(Bool.self, forKey: .online)
        unattendedOpenAllowed = try container.decodeIfPresent(Bool.self, forKey: .unattendedOpenAllowed)
        unattendedCloseAllowed = try container.decodeIfPresent(Bool.self, forKey: .unattendedCloseAllowed)
        vacationMode = try container.decodeIfPresent(Bool.self, forKey: .vacationMode)
        activeFaults = try container.decode([String].self, forKey: .activeFaults)
        lastServerUpdate = try container.decodeIfPresent(Date.self, forKey: .lastServerUpdate)
        unreadableSafetyFields = try container.decodeIfPresent([String].self, forKey: .unreadableSafetyFields) ?? []
    }

    /** Parses the devices endpoint's `{"items": [...]}` payload for one account. */
    public static func parseDevices(_ data: Data, account: MyQAccount) throws -> [DoorDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = root["items"] as? [Any] else {
            throw MyQError.malformedResponse
        }
        return try items.map { item in
            guard let raw = item as? [String: Any] else { throw MyQError.malformedResponse }
            let serial = ["serial_number", "id", "device_id"].lazy.compactMap { raw[$0] as? String }.first { !$0.isEmpty }
            guard let serial else { throw MyQError.malformedResponse }
            let state: [String: Any]
            switch raw["state"] {
            case nil, is NSNull: state = [:]
            case let object as [String: Any]: state = object
            default: throw MyQError.malformedResponse
            }
            var unreadable: [String] = []
            let faults: [String]
            switch state["active_fault_codes"] {
            case nil: faults = []
            case let list as [Any] where list.allSatisfy({ $0 is String }): faults = list.compactMap { $0 as? String }
            default:
                faults = []
                unreadable.append("active_fault_codes")
            }
            let vacation: Bool?
            switch state["in_vacation_mode"] {
            case nil: vacation = nil
            case let value?:
                vacation = strictBool(value)
                if vacation == nil { unreadable.append("in_vacation_mode") }
            }
            return DoorDevice(
                identity: DoorIdentity(accountID: account.id, serial: serial),
                accountName: account.name,
                name: (raw["name"] as? String) ?? serial,
                family: (raw["device_family"] as? String) ?? "unknown",
                state: DoorState(myQ: state["door_state"] as? String),
                online: strictBool(state["online"]),
                unattendedOpenAllowed: strictBool(state["is_unattended_open_allowed"]),
                unattendedCloseAllowed: strictBool(state["is_unattended_close_allowed"]),
                vacationMode: vacation,
                activeFaults: faults,
                lastServerUpdate: (state["last_update"] as? String).flatMap(parseDate),
                unreadableSafetyFields: unreadable
            )
        }
    }

    // JSONSerialization bridges 1 and 0 to NSNumber, so only genuine JSON booleans count.
    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func parseDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.withFractionalSeconds.date(from: raw) ?? ISO8601DateFormatter.plain.date(from: raw)
    }
}

extension ISO8601DateFormatter {
    // ISO8601DateFormatter is documented as thread-safe, so sharing these instances is safe.
    nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let plain = ISO8601DateFormatter()
}
