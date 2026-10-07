import Foundation

/** Friendly alternate names Siri accepts for common garage door names; "small door" and "big door" come first because Siri routes phrases containing "garage" to Apple Home. */
public enum DoorAliases {
    public static func defaults(for name: String) -> [String] {
        let words = DoorCatalog.normalize(name)
        let candidates: [String]
        if words.contains("single") || words.contains("one car") {
            candidates = ["small door", "small garage", "one car garage", "single garage"]
        } else if words.contains("two car") || words.contains("double") {
            candidates = ["big door", "big garage", "two car garage", "double garage"]
        } else {
            candidates = []
        }
        return candidates.filter { DoorCatalog.normalize($0) != words }
    }
}

/** One configured door: its stable identity, myQ display name and the alternate names Siri may hear. */
public struct CatalogDoor: Codable, Equatable, Hashable, Sendable {
    public let identity: DoorIdentity
    public let accountName: String
    public let name: String
    public let aliases: [String]

    public init(identity: DoorIdentity, accountName: String, name: String, aliases: [String]? = nil) {
        self.identity = identity
        self.accountName = accountName
        self.name = name
        self.aliases = aliases ?? DoorAliases.defaults(for: name)
    }

    /** The myQ name first, then each alias. */
    public var spokenNames: [String] { [name] + aliases }
}

/** The cached door list Siri and widgets resolve against, so naming a door never needs a network request. */
public struct DoorCatalog: Codable, Equatable, Sendable {
    public enum Resolution: Equatable, Sendable {
        case door(CatalogDoor)
        case ambiguous([CatalogDoor])
        case noMatch
    }

    public let doors: [CatalogDoor]

    /** Aliases claimed by more than one door are dropped so an alias can never pick the wrong door. */
    public init(doors: [CatalogDoor]) {
        var owners: [String: Set<DoorIdentity>] = [:]
        for door in doors {
            for alias in door.aliases { owners[Self.normalize(alias), default: []].insert(door.identity) }
            owners[Self.normalize(door.name), default: []].insert(door.identity)
        }
        self.doors = doors.map { door in
            let kept = door.aliases.filter { owners[Self.normalize($0)]?.count == 1 }
            return CatalogDoor(identity: door.identity, accountName: door.accountName, name: door.name, aliases: kept)
        }
    }

    public func door(for identity: DoorIdentity) -> CatalogDoor? {
        doors.first { $0.identity == identity }
    }

    public func resolve(_ spoken: String) -> Resolution {
        let wanted = Self.normalize(spoken)
        guard !wanted.isEmpty else { return .noMatch }
        let matches = doors.filter { door in door.spokenNames.contains { Self.normalize($0) == wanted } }
        switch matches.count {
        case 0: return .noMatch
        case 1: return .door(matches[0])
        default: return .ambiguous(matches)
        }
    }

    /** Reduces a door name or a spoken phrase to a canonical form, so everyday variations ("my big garage door", "to car garage", "small") compare equal; both sides go through it. */
    static func normalize(_ text: String) -> String {
        let cleaned = text.lowercased().replacingOccurrences(of: "'s", with: "").replacingOccurrences(of: "\u{2019}s", with: "")
        let spaced = cleaned.map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
        var words: [String] = []
        for raw in spaced.split(separator: " ").map(String.init) {
            words += splitJoinedCar(raw)
        }
        // Recognizer slips and synonyms that only make sense right before "car".
        for index in words.indices where index + 1 < words.count && words[index + 1] == "car" {
            switch words[index] {
            case "1", "won": words[index] = "one"
            case "2", "to", "too", "double": words[index] = "two"
            case "singles": words[index] = "single"
            default: break
            }
        }
        words = words.map { word in
            switch word {
            case "1": "one"
            case "2": "two"
            case "3": "three"
            case "garages": "garage"
            case "singles": "single"
            case "doors": "door"
            case "little": "small"
            case "large": "big"
            default: word
            }
        }
        while let first = words.first, ["the", "my", "our", "a"].contains(first) { words.removeFirst() }
        // "garage door" means the garage; a door named otherwise keeps its "door".
        words = words.enumerated().filter { !($0.element == "door" && $0.offset > 0 && words[$0.offset - 1] == "garage") }.map(\.element)
        if words.count > 1, words.first == "garage" {
            words.removeFirst()
            words.append("garage")
        }
        if !words.isEmpty, !words.contains("garage") { words.append("garage") }
        return words.joined(separator: " ")
    }

    /** Splits "1car", "onecar", "twocar", "singlecar" and "doublecar" into two words. */
    private static func splitJoinedCar(_ word: String) -> [String] {
        guard word.count > 3, word.hasSuffix("car") else { return [word] }
        let prefix = String(word.dropLast(3))
        return ["1", "2", "one", "two", "single", "double"].contains(prefix) ? [prefix, "car"] : [word]
    }
}

/** The catalog file in the App Group; only the app writes it, replacing it atomically. */
public struct DoorCatalogStore: Sendable {
    public enum StoreError: Error, Equatable, Sendable {
        case unreadable
        case malformedData
        case writeFailed
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    var fileURL: URL { directory.appendingPathComponent("door-catalog.json", isDirectory: false) }

    public func read() throws -> DoorCatalog {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return DoorCatalog(doors: [])
        } catch {
            throw StoreError.unreadable
        }
        guard let catalog = try? JSONDecoder().decode(DoorCatalog.self, from: data) else { throw StoreError.malformedData }
        return catalog
    }

    public func write(_ catalog: DoorCatalog) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            #if os(iOS)
            try encoder.encode(catalog).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try encoder.encode(catalog).write(to: fileURL, options: [.atomic])
            #endif
        } catch {
            throw StoreError.writeFailed
        }
    }

    /** Deletes the cached door list; a list that was never written counts as deleted. */
    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            throw StoreError.writeFailed
        }
    }
}

/** What discovery needs from myQ; MyQClient is the production implementation. */
public protocol DiscoveryAPI: Sendable {
    func accounts() async throws -> [MyQAccount]
    func devices(in account: MyQAccount) async throws -> [DoorDevice]
}

extension MyQClient: DiscoveryAPI {}

public enum DoorDiscovery {
    /** Lists every garage door in every account, sorted by name; any failure throws rather than returning a partial list. */
    public static func discover(using api: any DiscoveryAPI) async throws -> DoorCatalog {
        var doors: [CatalogDoor] = []
        for account in try await api.accounts() {
            for device in try await api.devices(in: account) where device.isGarageDoor {
                doors.append(CatalogDoor(identity: device.identity, accountName: account.name, name: device.name))
            }
        }
        return DoorCatalog(doors: doors.sorted { ($0.name, $0.identity.serial) < ($1.name, $1.identity.serial) })
    }
}
