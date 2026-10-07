import AppIntents
import GarageDoorKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import WidgetKit

/** State for the Doors tab: the myQ session, the door catalog, cached snapshots and app-screen commands. */
@MainActor
@Observable
final class DoorsModel {
    enum Session: Equatable {
        case signedIn
        case signedOut
        case unavailable
    }

    var catalog = DoorCatalog(doors: [])
    var snapshots: [DoorIdentity: DoorSnapshot] = [:]
    var session = Session.signedOut
    var message: String?
    var busy = false
    var offerClipboardClear = false
    var traffic: String?
    var requestCount = 0
    var findingDoors = false
    var signInProblem: String?
    var findResult: String?
    var flashes: [DoorIdentity: String] = [:]
    private var flashTasks: [DoorIdentity: Task<Void, Never>] = [:]
    let setupProblem: String?
    private let environment: GarageEnvironment?

    init() {
        do {
            environment = try GarageEnvironment.live()
            setupProblem = nil
        } catch {
            environment = nil
            setupProblem = "This build is missing its App Group or Keychain group (\(error)). Rebuild with Signing.local.xcconfig set."
        }
        reload()
    }

    func reload() {
        guard let environment else {
            session = .unavailable
            return
        }
        catalog = (try? environment.catalogStore.read()) ?? DoorCatalog(doors: [])
        snapshots = Dictionary(((try? environment.snapshotStore.read()) ?? []).map { ($0.device.identity, $0) }) { _, newer in newer }
        let log = (try? environment.trafficLog.read()) ?? []
        traffic = TrafficLog.lastBurst(log)?.text
        requestCount = log.count
        do {
            session = try environment.tokenStore.read() == nil ? .signedOut : .signedIn
        } catch {
            session = .unavailable
        }
    }

    func signIn() async {
        guard let environment else { return }
        busy = true
        defer { busy = false }
        signInProblem = nil
        do {
            #if canImport(UIKit)
            try await environment.signIn(with: WebSignIn())
            #endif
        } catch let error as SignInError {
            signInProblem = error.description
            reload()
            return
        } catch {
            signInProblem = "The session couldn't be saved. Unlock the iPhone and try again."
            reload()
            return
        }
        message = nil
        await findDoors()
    }

    func importToken(_ pasted: String) async -> Bool {
        guard let environment else { return false }
        busy = true
        defer { busy = false }
        do {
            try await environment.importer.importToken(pasted)
        } catch let error as SessionImporter.ImportError {
            message = error.description
            reload()
            return false
        } catch {
            message = "The token couldn't be saved. Unlock the iPhone and try again."
            reload()
            return false
        }
        message = "Session imported."
        offerClipboardClear = true
        await findDoors()
        return true
    }

    /** The shareable JSON request log, offered once the log has entries. */
    var requestLogExport: RequestLogExport? {
        guard let environment, traffic != nil else { return nil }
        return RequestLogExport(log: environment.trafficLog, appVersion: RequestLogExport.appVersion())
    }

    func findDoors() async {
        guard let environment else { return }
        busy = true
        findingDoors = true
        defer {
            busy = false
            findingDoors = false
        }
        do {
            let found = try await environment.discoverDoors()
            GarageTilesShortcuts.updateAppShortcutParameters()
            findResult = found.doors.isEmpty
                ? "No doors found. This myQ account has no garage doors. Set them up in the myQ app first, or sign in with a different account."
                : "Found \(found.doors.count) door\(found.doors.count == 1 ? "" : "s")."
        } catch TokenError.signInRequired {
            findResult = CommandOutcome.signInRequired.dialog(doorName: "")
        } catch {
            findResult = "Couldn't reach myQ to list doors. Try again."
        }
        announce(findResult)
        reload()
    }

    func perform(_ request: DoorRequest, on door: CatalogDoor) async {
        guard let environment else { return }
        busy = true
        defer { busy = false }
        let result = await environment.perform(request, on: door.identity)
        flash(result.outcome.cardMessage(doorName: door.name), on: door)
        announce(result.dialog)
        WidgetCenter.shared.reloadAllTimelines()
        reload()
    }

    /** Runs what a tap on a door card means: one explicit command, or a short explanation with no request at all. */
    func tap(_ card: DoorCard, on door: CatalogDoor) {
        switch card.tap {
        case .send(let action): Task { await perform(action == .open ? .open : .close, on: door) }
        case .explain(let text):
            flash(text, on: door)
            announce("\(door.name). \(text)")
        case .none: break
        }
    }

    // Shows a short line under one card for a few seconds, as the design does after a tap.
    private func flash(_ text: String?, on door: CatalogDoor) {
        flashTasks[door.identity]?.cancel()
        flashes[door.identity] = text
        guard text != nil else { return }
        flashTasks[door.identity] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.flashes[door.identity] = nil
        }
    }

    // Speaks a result to VoiceOver users, since the card's color and icon change silently.
    private func announce(_ text: String?) {
        guard let text else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    func signOut() async {
        guard let environment else { return }
        busy = true
        defer { busy = false }
        do {
            try await environment.signOut()
            findResult = nil
            flashes = [:]
            message = "Signed out. The session and all saved door data are deleted from this iPhone."
        } catch let error as GarageEnvironment.SignOutError {
            message = error.description
        } catch {
            message = GarageEnvironment.SignOutError.localDataNotRemoved.description
        }
        GarageTilesShortcuts.updateAppShortcutParameters()
        WidgetCenter.shared.reloadAllTimelines()
        reload()
    }

    /** True while anything is saved on the device, so Sign out stays available to clear leftovers even without a session. */
    var hasLocalData: Bool {
        session == .signedIn || !catalog.doors.isEmpty || !snapshots.isEmpty || traffic != nil
    }

    func clearClipboard() {
        #if canImport(UIKit)
        UIPasteboard.general.items = []
        #endif
        offerClipboardClear = false
    }
}

/** Setup and control for the real doors, laid out like the app design: sign in, find doors, door cards, then Siri, the request log and the account. */
struct DoorsView: View {
    @State private var model = DoorsModel()
    @State private var token = ""
    @State private var showTokenImport = false
    @State private var confirmingSignOut = false
    @AppStorage("siriTip.closeDoor.visible") private var showSiriTip = true

    var body: some View {
        NavigationStack {
            Form {
                if let problem = model.setupProblem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
                if model.session != .signedIn {
                    signInSection
                }
                doorsSection
                if !model.catalog.doors.isEmpty {
                    siriSection
                }
                lockedPhoneSection
                if model.requestCount > 0 {
                    requestLogSection
                }
                accountSection
            }
            .navigationTitle("Garage Doors")
            .refreshable { model.reload() }
            .confirmationDialog("Sign out and delete?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes everything the app saved: your sign-in, doors, nicknames and request log.")
            }
        }
        .onAppear { model.reload() }
    }

    private var signInSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Open your garage with one tap").font(.title2.bold())
                Text("Sign in with your myQ account to find your doors.")
            }
            .padding(.vertical, 4)
            if let problem = model.signInProblem {
                Text(problem).foregroundStyle(.primary).accessibilityIdentifier("signInProblem")
            }
            Button("Sign in with myQ") { Task { await model.signIn() } }
                .font(.headline)
                .disabled(model.setupProblem != nil || model.busy)
                .accessibilityIdentifier("signInButton")
            tokenImport
            messageRow
        } header: {
            header("Sign in")
        } footer: {
            Text("You\u{2019}ll sign in on myQ\u{2019}s own page. Your password and verification code go to myQ, not to this app.")
                .foregroundStyle(.primary)
        }
    }

    private var tokenImport: some View {
        DisclosureGroup("Advanced: import a token", isExpanded: $showTokenImport) {
            SecureField("Paste a myQ token", text: $token)
                .textContentType(.password)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("tokenField")
            Button("Import token") {
                let pasted = token
                Task {
                    if await model.importToken(pasted) { token = "" }
                }
            }
            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            .accessibilityIdentifier("importTokenButton")
        }
        .accessibilityIdentifier("advancedTokenImport")
    }

    private var doorsSection: some View {
        Section {
            if model.findingDoors {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading) {
                        Text("Finding your doors\u{2026}").font(.headline)
                        Text("Asking myQ which garage doors are on your account.").font(.footnote)
                    }
                }
                .accessibilityElement(children: .combine)
            } else if let result = model.findResult {
                Text(result).foregroundStyle(.primary).accessibilityIdentifier("findResult")
            }
            if model.catalog.doors.isEmpty, !model.findingDoors {
                Text("No doors yet. Sign in with myQ to find them.")
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("noDoorsMessage")
            }
            // Ages like "Updated 2 min ago" refresh on their own while the screen is open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 16) {
                    ForEach(model.catalog.doors, id: \.identity) { door in
                        DoorCardView(
                            door: door, card: DoorCard(snapshot: model.snapshots[door.identity], now: context.date), flash: model.flashes[door.identity],
                            enabled: model.session == .signedIn && !model.busy,
                            tap: { card in model.tap(card, on: door) },
                            command: { request in Task { await model.perform(request, on: door) } }
                        )
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
            if model.session == .signedIn {
                Button("Find doors") { Task { await model.findDoors() } }
                    .disabled(model.busy)
            }
        } header: {
            header("Doors")
        }
    }

    private var siriSection: some View {
        Section {
            Text(siriExample).foregroundStyle(.primary).accessibilityIdentifier("siriExample")
            #if os(iOS)
            if let first = model.catalog.doors.first {
                SiriTipView(intent: CloseDoorIntent(door: DoorEntity(first)), isVisible: $showSiriTip)
                    .accessibilityIdentifier("siriTip")
            }
            #endif
        } header: {
            header("Siri")
        }
    }

    // The design's examples left out the app name and said "garage", which sends Siri to Apple Home; these are the phrases that work.
    private var siriExample: String {
        let names = model.catalog.doors.map { $0.aliases.first ?? $0.name }
        let first = names.first ?? "small door"
        let second = names.dropFirst().first ?? first
        return "Say \u{201C}Open \(first) with Whisper Lift\u{201D} or \u{201C}Close \(second) with Whisper Lift\u{201D}."
    }

    private var lockedPhoneSection: some View {
        Section {
            Text("Siri and these buttons work while the iPhone is locked. Anyone who can use Siri or CarPlay with this phone can open the doors. Sign out to stop that.")
                .font(.footnote)
                .accessibilityIdentifier("lockedPhoneWarning")
        } footer: {
            #if os(iOS)
            // Opens Whisper Lift's page in the Shortcuts app, which lists every phrase Siri accepts.
            ShortcutsLink()
                .accessibilityIdentifier("shortcutsLink")
            #endif
        }
    }

    private var requestLogSection: some View {
        Section {
            LabeledContent {
                Text("\(model.requestCount) request\(model.requestCount == 1 ? "" : "s") saved").foregroundStyle(.primary).accessibilityIdentifier("requestCount")
            } label: {
                Text("Every request to myQ")
            }
            if let traffic = model.traffic {
                LabeledContent {
                    Text(traffic).foregroundStyle(.primary).accessibilityIdentifier("trafficSummary")
                } label: {
                    Text("Last myQ exchange")
                }
                .font(.footnote)
            }
            if let export = model.requestLogExport {
                ShareLink(item: export, preview: SharePreview("Whisper Lift request log")) {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("exportRequestLogButton")
            }
        } header: {
            header("Request log")
        }
    }

    private var accountSection: some View {
        Section {
            // The label is a separate view, as on the Spike tab, so the value keeps its own accessibility label.
            LabeledContent {
                Text(sessionText).foregroundStyle(.primary).accessibilityIdentifier("sessionStatus")
            } label: {
                Text("Status")
            }
            if model.session == .signedIn {
                Button("Sign in to myQ again") { Task { await model.signIn() } }
                    .disabled(model.setupProblem != nil || model.busy)
                tokenImport
            }
            if model.session == .signedIn {
                messageRow
            }
            if model.offerClipboardClear {
                Button("Clear the clipboard") { model.clearClipboard() }
            }
            if model.hasLocalData {
                Button("Sign out", role: .destructive) { confirmingSignOut = true }
                    .disabled(model.busy)
                    .accessibilityIdentifier("signOutButton")
            }
        } header: {
            header("Account")
        }
    }

    // Import and sign-out results appear under the section the person just used, so they are on screen without scrolling.
    @ViewBuilder private var messageRow: some View {
        if let message = model.message {
            Text(message).font(.footnote).accessibilityIdentifier("importMessage")
        }
    }

    // Bold headline type counts as large text, which clears the contrast audit with margin.
    private func header(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.primary)
    }

    private var sessionText: String {
        switch model.session {
        case .signedIn: "Signed in to myQ"
        case .signedOut: "Not signed in"
        case .unavailable: "Unavailable"
        }
    }
}

/** One door drawn the way the design shows it: a filled card you tap for closed, open and moving, or an outlined problem card with the app's Open and Close buttons. */
struct DoorCardView: View {
    let door: CatalogDoor
    let card: DoorCard
    let flash: String?
    let enabled: Bool
    let tap: (DoorCard) -> Void
    let command: (DoorRequest) -> Void

    var body: some View {
        if card.isProblem {
            problemCard
        } else {
            Button { tap(card) } label: { filledCard }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel(accessibilityText)
                .accessibilityIdentifier("doorCard-\(door.identity.serial)")
        }
    }

    private var filledCard: some View {
        VStack(spacing: 10) {
            Text(door.name).font(.title3.bold())
            Image(systemName: DoorCardStyle.symbol(card.icon)).font(.system(size: 56, weight: .regular)).accessibilityHidden(true)
            Text(card.title).font(.title2.bold())
            Text(flash ?? card.detail).font(.body.weight(.semibold))
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding(20)
        .background(DoorCardStyle.fill(card.tone), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .opacity(enabled ? 1 : 0.6)
    }

    private var problemCard: some View {
        let accent = DoorCardStyle.accent(card.tone)
        return VStack(alignment: .leading, spacing: 10) {
            Text(door.name).font(.title3.bold()).foregroundStyle(DoorCardStyle.text)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: DoorCardStyle.symbol(card.icon)).font(.title).foregroundStyle(accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(.title3.bold()).foregroundStyle(card.tone == .warning ? accent : DoorCardStyle.text)
                    Text(flash ?? card.detail).foregroundStyle(DoorCardStyle.text)
                }
            }
            if card.icon != .signIn {
                HStack {
                    Button("Open") { command(.open) }.buttonStyle(.borderedProminent).tint(accent)
                    Button("Close") { command(.close) }.buttonStyle(.borderedProminent).tint(accent)
                }
                .foregroundStyle(DoorCardStyle.background)
                .disabled(!enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(DoorCardStyle.background, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(accent, style: StrokeStyle(lineWidth: 4, dash: card.dashedBorder ? [12, 8] : []))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("doorCard-\(door.identity.serial)")
    }

    private var accessibilityText: String {
        [door.name, card.title, flash ?? card.detail, card.hint].compactMap { $0 }.joined(separator: ". ") + "."
    }
}

/** The design's palette and icons; white on these fills keeps at least 4.5:1 contrast. */
enum DoorCardStyle {
    static let background = Color(red: 0x24 / 255, green: 0x1B / 255, blue: 0x2F / 255)
    static let text = Color(red: 0xF4 / 255, green: 0xEB / 255, blue: 0xFF / 255)

    static func fill(_ tone: DoorCard.Tone) -> Color {
        switch tone {
        case .closed: Color(red: 0xB4 / 255, green: 0x23 / 255, blue: 0x18 / 255)
        case .open: Color(red: 0x06 / 255, green: 0x76 / 255, blue: 0x47 / 255)
        case .moving: Color(red: 0x6B / 255, green: 0x3F / 255, blue: 0xA0 / 255)
        case .warning, .neutral: background
        }
    }

    static func accent(_ tone: DoorCard.Tone) -> Color {
        tone == .warning ? Color(red: 0xFD / 255, green: 0xB0 / 255, blue: 0x22 / 255) : Color(red: 0xD0 / 255, green: 0xC6 / 255, blue: 0xE0 / 255)
    }

    static func symbol(_ icon: DoorCard.Icon) -> String {
        switch icon {
        case .closed: "door.garage.closed"
        case .open: "door.garage.open"
        case .opening: "arrow.up.to.line"
        case .closing: "arrow.down.to.line"
        case .warning: "exclamationmark.triangle.fill"
        case .question: "questionmark.circle"
        case .offline: "wifi.slash"
        case .locked: "lock.fill"
        case .clock: "clock"
        case .signIn: "person.crop.circle.badge.exclamationmark"
        }
    }
}
