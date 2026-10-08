import AppIntents
import GarageDoorKit

/** A garage door Siri can name; it resolves from the cached catalog, never from a network request. */
struct DoorEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Garage Door" }
    static let defaultQuery = DoorQuery()

    let id: String
    let name: String
    let aliases: [String]

    init(_ door: CatalogDoor) {
        id = door.identity.entityIdentifier
        name = door.name
        aliases = door.aliases
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", synonyms: aliases.map { "\($0)" })
    }
}

/** Enumerable because the door list is small and stored on the device, so Siri can see every door and nickname without a search. */
struct DoorQuery: EnumerableEntityQuery, EntityStringQuery {
    func allEntities() async throws -> [DoorEntity] {
        try Self.catalog().doors.map(DoorEntity.init)
    }

    func entities(for identifiers: [DoorEntity.ID]) async throws -> [DoorEntity] {
        let catalog = try Self.catalog()
        return identifiers.compactMap { DoorIdentity(entityIdentifier: $0).flatMap(catalog.door(for:)).map(DoorEntity.init) }
    }

    func suggestedEntities() async throws -> [DoorEntity] {
        try Self.catalog().doors.map(DoorEntity.init)
    }

    func entities(matching string: String) async throws -> [DoorEntity] {
        switch try Self.catalog().resolve(string) {
        case .door(let door): [DoorEntity(door)]
        case .ambiguous(let doors): doors.map(DoorEntity.init)
        case .noMatch: []
        }
    }

    private static func catalog() throws -> DoorCatalog {
        try AppEnvironment.current().catalogStore.read()
    }
}
