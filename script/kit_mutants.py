#!/usr/bin/env python3
"""Applies hand-picked mutants to GarageDoorKit sources one at a time and requires the Swift tests to kill each one; Muter misreports closures, so these are explicit."""

import subprocess
import sys
from pathlib import Path

KIT = Path(__file__).resolve().parent.parent / "ios/GarageTiles/GarageTilesKit"
SRC = KIT / "Sources/GarageDoorKit"

# (file, original text, mutated text, test filter, what the mutant breaks)
MUTANTS = [
    ("DoorCard.swift", "now.timeIntervalSince(snapshot.fetchedAt) >= staleAfter", "now.timeIntervalSince(snapshot.fetchedAt) > staleAfter", "DoorCardTests", "stale boundary"),
    ("DoorCard.swift", "now.timeIntervalSince(snapshot.fetchedAt) >= movingStaleAfter", "now.timeIntervalSince(snapshot.fetchedAt) > movingStaleAfter", "DoorCardTests", "moving-stale boundary"),
    ("DoorCard.swift", "snapshot.problem == .unreachable || snapshot.problem == .rateLimited ||", "snapshot.problem == .rateLimited ||", "DoorCardTests", "unreachable no longer last-known"),
    ("DoorCard.swift", "snapshot.problem == .unreachable || snapshot.problem == .rateLimited ||", "snapshot.problem == .unreachable ||", "DoorCardTests", "rate-limited no longer last-known"),
    ("DoorCard.swift", "[.opening, .closing].contains(device.state) &&", "[.opening].contains(device.state) &&", "DoorCardTests", "closing never goes stale"),
    ("DoorCard.swift", "map { now < $0.addingTimeInterval(cooldown) }", "map { now > $0.addingTimeInterval(cooldown) }", "DoorCardTests", "cooldown inverted"),
    ("DoorCard.swift", 'title: action == .open ? "Opening\\u{2026}" : "Closing\\u{2026}", detail: "Sending', 'title: action == .open ? "Closing\\u{2026}" : "Opening\\u{2026}", detail: "Sending', "DoorCardTests", "sending card shows the wrong direction"),
    ("DoorCard.swift", "tap: coolingDown ? .explain(justMoved) : .send(isOpen ? .close : .open)", "tap: coolingDown ? .explain(justMoved) : .send(isOpen ? .open : .close)", "DoorCardTests", "a tap sends the wrong command"),
    ("DoorCard.swift", "case ..<60: return \"Updated just now\"", "case ..<61: return \"Updated just now\"", "DoorCardTests", "age wording boundary"),
    ("DoorCard.swift", "case .refused(.coolingDown): DoorCard.justMoved", "case .refused(.coolingDown): DoorCard.alreadyMoving", "CardMessageTests", "cooldown message"),
    ("DoorCard.swift", "device.unattendedOpenAllowed == false, device.unattendedCloseAllowed == false", "device.unattendedOpenAllowed == false || device.unattendedCloseAllowed == false", "DoorCardTests", "remote-off when only one direction is blocked"),
    ("DoorCard.swift", "} else if device.vacationMode == true {", "} else if device.vacationMode != false {", "DoorCardTests", "unknown vacation mode treated as on"),
    ("GarageEnvironment.swift", "if state != .opening && state != .closing { return }", "if state != .opening || state != .closing { return }", "FollowUpTests", "follow-up stops while still moving"),
    ("GarageEnvironment.swift", "            await onCheck()\n", "", "FollowUpTests", "screen not redrawn after a check"),
    ("GarageEnvironment.swift", "if result == .signInRequired || result == .noDoors { return }", "if result == .noDoors { return }", "FollowUpTests", "follow-up keeps going without a session"),
    ("GarageEnvironment.swift", "lastCommand: cached?.lastCommand, lastCommandAt: cached?.lastCommandAt, problem: nil)", "lastCommand: cached?.lastCommand, lastCommandAt: nil, problem: nil)", "StatusRefreshTests", "refresh forgets the cooldown"),
    ("GarageEnvironment.swift", "lastCommand: cached?.lastCommand, lastCommandAt: cached?.lastCommandAt, problem: nil)", "lastCommand: cached?.lastCommand, lastCommandAt: cached?.lastCommandAt, problem: cached?.problem)", "StatusRefreshTests", "a good read keeps the old problem"),
    ("GarageEnvironment.swift", "_ = try? await commandLock.withDoorLock(door.identity) {\n            let cached = try? snapshotStore.snapshot(for: door.identity)\n            if let next = update(cached) { try? snapshotStore.upsert(next) }\n        }", "let cached = try? snapshotStore.snapshot(for: door.identity)\n        if let next = update(cached) { try? snapshotStore.upsert(next) }", "StatusRefreshTests", "refresh overwrites a running command's record"),
    ("GarageEnvironment.swift", "await mark(doors, .unreachable)", "await mark(doors, .rateLimited)", "StatusRefreshTests", "failure marked as the wrong problem"),
    ("GarageEnvironment.swift", "                try trafficLog.remove()\n", "", "GarageEnvironmentSignOutTests", "sign-out leaves the request log"),
    ("TokenCoordinator.swift", "try await lock.withLock(timeout: lockTimeout) {\n            do {\n                try removable.remove()", "try await ImmediateNoLock().run {\n            do {\n                try removable.remove()", "SignOutTests", "sign-out skips the refresh lock"),
    ("CheckThrottle.swift", "if !force, let lastCheck,", "if let lastCheck,", "CheckThrottleTests", "pull to refresh can be skipped"),
    ("CheckThrottle.swift", "        lastCheck = now\n", "", "CheckThrottleTests", "duplicate launch check not skipped"),
    ("Traffic.swift", "request.status.map { !(200..<300).contains($0) } ?? true", "request.status.map { (200..<300).contains($0) } ?? true", "TrafficExportTests", "failed-request count inverted"),
    ("Traffic.swift", 'String(format: ".%03dZ", fraction)', 'String(format: ".%dZ", fraction)', "TrafficExportTests", "milliseconds lose leading zeros"),
    ("Traffic.swift", "let endpoint = MeteredTransport.template(entry.path)", "let endpoint = entry.path", "TrafficExportTests", "export can leak an identifier"),
    ("MyQConfiguration.swift", 'guard !raw.isEmpty, !raw.hasPrefix("$(") else', "guard !raw.isEmpty else", "MyQConfigurationTests", "unexpanded setting accepted"),
    ("MyQSignIn.swift", 'guard items["state"] == expectedState else { throw SignInError.stateMismatch }', "", "CallbackParsingTests", "forged sign-in callback accepted"),
    ("MyQSignIn.swift", "guard let configuration else { throw SignInError.notConfigured }", "guard let configuration = configuration ?? (try? MyQConfiguration(info: [MyQConfiguration.appCheckDebugTokenInfoKey: \"00000000-1111-4222-8333-444444444444\"])) else { throw SignInError.notConfigured }", "SignInFlowTests", "sign-in runs without configuration"),
]

HELPER = "\nprivate struct ImmediateNoLock { func run<T>(_ body: () async throws -> T) async rethrows -> T { try await body() } }\n"


def run(filter_name: str) -> tuple[bool, bool]:
    result = subprocess.run(["swift", "test", "--filter", filter_name], cwd=KIT, capture_output=True, text=True)
    output = result.stdout + result.stderr
    compiled = "error:" not in output or "Test run with" in output
    return result.returncode == 0, compiled


def main() -> int:
    killed = survived = invalid = 0
    for name, original, mutated, test_filter, label in MUTANTS:
        path = SRC / name
        source = path.read_text()
        if source.count(original) != 1:
            print(f"MISSING   {name}: {label}")
            invalid += 1
            continue
        changed = source.replace(original, mutated) + (HELPER if "ImmediateNoLock" in mutated else "")
        try:
            path.write_text(changed)
            passed, compiled = run(test_filter)
        finally:
            path.write_text(source)
        if not compiled:
            print(f"INVALID   {name}: {label} (does not compile)")
            invalid += 1
        elif passed:
            print(f"SURVIVED  {name}: {label}")
            survived += 1
        else:
            print(f"killed    {name}: {label}")
            killed += 1
    print(f"{killed}/{killed + survived} killed, {invalid} invalid")
    return 0 if survived == 0 and invalid == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
