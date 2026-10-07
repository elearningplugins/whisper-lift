import Foundation
import PropertyTestSupport
import Testing
@testable import GarageDoorKit

@Suite struct DoorStateTests {
    @Test(arguments: [
        ("open", DoorState.open), ("closed", .closed), ("opening", .opening), ("closing", .closing), ("stopped", .stopped),
        ("OPEN", .open), ("Closed", .closed), (" closed", .unknown), ("autoreverse", .unknown), ("transition", .unknown), ("", .unknown),
    ])
    func normalizesMyQStates(_ raw: String, _ expected: DoorState) {
        #expect(DoorState(myQ: raw) == expected)
    }

    @Test func missingStateIsUnknown() {
        #expect(DoorState(myQ: nil) == .unknown)
    }

    @Test func onlyOpenAndClosedAreTerminal() {
        #expect(DoorState.allCases.filter(\.isTerminal) == [.open, .closed])
    }

    @Test func movingStatesAreOpeningAndClosing() {
        #expect(DoorState.allCases.filter(\.isMoving) == [.opening, .closing])
    }

    @Test func everyStateHasADistinctLabel() {
        #expect(DoorState.allCases.map(\.label) == ["Open", "Closed", "Opening", "Closing", "Stopped", "Unknown"])
    }

    @Test func normalizationNeverInventsATerminalState() {
        forAll(iterations: 500, { rng in Gen.string(&rng, from: ["o", "p", "e", "n", "c", "l", "s", "d", " ", "-", "OPEN", "closed", "x"]) }) { raw in
            let state = DoorState(myQ: raw)
            return !state.isTerminal || raw.lowercased() == state.rawValue
        }
    }
}

@Suite struct DoorIdentityTests {
    @Test func entityIdentifierRoundTrips() throws {
        let identity = DoorIdentity(accountID: "account-1", serial: "CG0812345678")
        #expect(DoorIdentity(entityIdentifier: identity.entityIdentifier) == identity)
    }

    @Test func entityIdentifierIsStableText() {
        #expect(DoorIdentity(accountID: "a|b", serial: "c").entityIdentifier == "3:a|bc")
    }

    @Test func separatorsInsideValuesCannotCollide() {
        let first = DoorIdentity(accountID: "a:1", serial: "b")
        let second = DoorIdentity(accountID: "a", serial: "1:b")
        #expect(first.entityIdentifier != second.entityIdentifier)
    }

    @Test(arguments: ["", "x", "3:ab", "-1:abc", "99999999999999999999:a", ":abc", "0:", "1:a"])
    func malformedIdentifiersAreRejected(_ raw: String) {
        #expect(DoorIdentity(entityIdentifier: raw) == nil)
    }

    @Test func roundTripsForArbitraryValues() {
        let pieces = ["a", "1", ":", "|", "/", " ", "é", "🚗", "0", "-"]
        forAll(iterations: 500, { rng in (Gen.string(&rng, from: pieces), Gen.string(&rng, from: pieces)) }) { account, serial in
            let identity = DoorIdentity(accountID: account, serial: serial)
            guard !account.isEmpty, !serial.isEmpty else { return DoorIdentity(entityIdentifier: identity.entityIdentifier) == nil }
            return DoorIdentity(entityIdentifier: identity.entityIdentifier) == identity
        }
    }
}

@Suite struct DeviceParsingTests {
    private let account = MyQAccount(id: "account-1", name: "Home")

    private func parse(_ json: String) throws -> [DoorDevice] {
        try DoorDevice.parseDevices(Data(json.utf8), account: account)
    }

    @Test func parsesEveryDeviceWithItsSafetyFields() throws {
        let devices = try parse("""
        {"items":[
          {"serial_number":"hub-1","name":"Hub","device_family":"gateway","state":{"online":true}},
          {"serial_number":"door-1","name":"Big","device_family":"garagedoor","state":{
            "door_state":"closed","online":true,"is_unattended_open_allowed":true,"is_unattended_close_allowed":false,
            "in_vacation_mode":true,"active_fault_codes":["E1"],"last_update":"2026-10-06T12:00:00.123Z"}}
        ]}
        """)
        #expect(devices.count == 2)
        let door = devices[1]
        #expect(door.identity == DoorIdentity(accountID: "account-1", serial: "door-1"))
        #expect(door.name == "Big")
        #expect(door.family == "garagedoor")
        #expect(door.isGarageDoor)
        #expect(!devices[0].isGarageDoor)
        #expect(door.state == .closed)
        #expect(door.online == true)
        #expect(door.unattendedOpenAllowed == true)
        #expect(door.unattendedCloseAllowed == false)
        #expect(door.vacationMode == true)
        #expect(door.activeFaults == ["E1"])
        #expect(door.lastServerUpdate == ISO8601DateFormatter.withFractionalSeconds.date(from: "2026-10-06T12:00:00.123Z"))
    }

    @Test func missingOrWrongTypedFlagsAreNilNotFalse() throws {
        let door = try parse(#"{"items":[{"serial_number":"d","device_family":"garagedoor","state":{"online":"yes","is_unattended_open_allowed":1}}]}"#)[0]
        #expect(door.online == nil)
        #expect(door.unattendedOpenAllowed == nil)
        #expect(door.unattendedCloseAllowed == nil)
        #expect(door.vacationMode == nil)
        #expect(door.activeFaults == [])
        #expect(door.state == .unknown)
        #expect(door.name == "d")
    }

    @Test func fallsBackToIdThenDeviceIdForTheSerial() throws {
        #expect(try parse(#"{"items":[{"id":"by-id","device_family":"gateway"}]}"#)[0].identity.serial == "by-id")
        #expect(try parse(#"{"items":[{"device_id":"by-device-id","device_family":"gateway"}]}"#)[0].identity.serial == "by-device-id")
    }

    @Test(arguments: [
        "not json", "[]", #"{"items":{}}"#, #"{"other":[]}"#, #"{"items":[1]}"#,
        #"{"items":[{"name":"no id"}]}"#, #"{"items":[{"serial_number":"d","state":[]}]}"#, #"{"items":[{"serial_number":""}]}"#,
    ])
    func malformedPayloadsAreRejected(_ json: String) {
        #expect(throws: MyQError.malformedResponse) { try parse(json) }
    }

    @Test func parsesAccounts() throws {
        let accounts = try MyQAccount.parseAccounts(Data(#"{"accounts":[{"id":"a1","name":"Home"},{"id":"a2"}]}"#.utf8))
        #expect(accounts == [MyQAccount(id: "a1", name: "Home"), MyQAccount(id: "a2", name: "a2")])
    }

    @Test(arguments: ["{}", #"{"accounts":[{"name":"x"}]}"#, #"{"accounts":[{"id":""}]}"#, "null"])
    func malformedAccountsAreRejected(_ json: String) {
        #expect(throws: MyQError.malformedResponse) { try MyQAccount.parseAccounts(Data(json.utf8)) }
    }
}

enum Gen {
    static func string(_ rng: inout SplitMix64, from pieces: [String], maxPieces: Int = 6) -> String {
        (0..<Int.random(in: 0...maxPieces, using: &rng)).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &rng)] }.joined()
    }
}

@Suite struct SafetyFieldParsingTests {
    private let account = MyQAccount(id: "account-1", name: "Home")

    private func door(_ stateJSON: String) throws -> DoorDevice {
        try DoorDevice.parseDevices(Data(#"{"items":[{"serial_number":"d","device_family":"garagedoor","state":\#(stateJSON)}]}"#.utf8), account: account)[0]
    }

    // The owner's openers omit these fields entirely, so absent means "not reported", not "unsafe".
    @Test func absentFaultAndVacationFieldsAreNotReportedAndReadable() throws {
        let parsed = try door(#"{"door_state":"closed","online":true}"#)
        #expect(parsed.activeFaults == [])
        #expect(parsed.vacationMode == nil)
        #expect(parsed.unreadableSafetyFields == [])
    }

    @Test(arguments: [
        (#"{"active_fault_codes":"E1"}"#, ["active_fault_codes"]),
        (#"{"active_fault_codes":{"E1":true}}"#, ["active_fault_codes"]),
        (#"{"active_fault_codes":["E1", 7]}"#, ["active_fault_codes"]),
        (#"{"active_fault_codes":null}"#, ["active_fault_codes"]),
        (#"{"in_vacation_mode":"true"}"#, ["in_vacation_mode"]),
        (#"{"in_vacation_mode":1}"#, ["in_vacation_mode"]),
        (#"{"in_vacation_mode":null}"#, ["in_vacation_mode"]),
        (#"{"active_fault_codes":7,"in_vacation_mode":"no"}"#, ["active_fault_codes", "in_vacation_mode"]),
    ])
    func presentButMalformedSafetyFieldsAreFlagged(_ stateJSON: String, _ expected: [String]) throws {
        #expect(try door(stateJSON).unreadableSafetyFields == expected)
    }

    @Test func wellFormedFieldsAreReadNormally() throws {
        let parsed = try door(#"{"active_fault_codes":["E1","E2"],"in_vacation_mode":false}"#)
        #expect(parsed.activeFaults == ["E1", "E2"])
        #expect(parsed.vacationMode == false)
        #expect(parsed.unreadableSafetyFields == [])
    }
}

@Suite struct MalformedSafetyPolicyTests {
    private func device(unreadable: [String]) -> DoorDevice {
        DoorDevice(
            identity: DoorIdentity(accountID: "a", serial: "d"), accountName: "Home", name: "Big", family: "garagedoor", state: .closed, online: true,
            unattendedOpenAllowed: true, unattendedCloseAllowed: true, vacationMode: nil, activeFaults: [], lastServerUpdate: nil, unreadableSafetyFields: unreadable
        )
    }

    @Test(arguments: [DoorRequest.open, .toggle])
    func unreadableSafetyDataBlocksCommands(_ request: DoorRequest) {
        let decision = SafetyPolicy(cooldown: 10).decide(request, lookup: .found(device(unreadable: ["active_fault_codes"])), inFlight: false, lastCommandAt: nil, now: .now)
        #expect(decision == .refuse(.unreadableSafetyData))
    }

    @Test func readableSafetyDataStillSends() {
        #expect(SafetyPolicy(cooldown: 10).decide(.open, lookup: .found(device(unreadable: [])), inFlight: false, lastCommandAt: nil, now: .now) == .send(.open))
    }

    @Test func unreadableSafetyDataDialog() {
        #expect(CommandOutcome.refused(.unreadableSafetyData).dialog(doorName: "Big") == "myQ sent safety information for Big that I couldn't read, so I didn't move it.")
    }
}
