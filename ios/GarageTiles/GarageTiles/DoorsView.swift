import AppIntents
import GarageDoorKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/** State for the doors screen: the myQ session, the door catalog, cached snapshots and app-screen commands. */
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
    var checkingStatus = false
    // Doors tapped a moment ago and still waiting for myQ to accept; their cards show Opening or Closing right away.
    var pending: [DoorIdentity: DoorAction] = [:]
    private var followUps: [DoorIdentity: Task<Void, Never>] = [:]
    private var throttle = CheckThrottle()
    private var flashTasks: [DoorIdentity: Task<Void, Never>] = [:]
    let setupProblem: String?
    private let environment: GarageEnvironment?

    init() {
        do {
            environment = try Self.makeEnvironment()
            setupProblem = nil
        } catch {
            environment = nil
            setupProblem = "This build is missing its App Group or Keychain group (\(error)). Rebuild with Signing.local.xcconfig set."
        }
        reload()
    }

    private static func makeEnvironment() throws -> GarageEnvironment {
        #if DEBUG
        if UITestSandbox.isActive { return UITestSandbox.environment() }
        #endif
        return try GarageEnvironment.live()
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

    /** The shareable JSON request log, offered whenever the app is signed in, as the design's header shows. */
    var requestLogExport: RequestLogExport? {
        guard let environment, session == .signedIn else { return nil }
        return RequestLogExport(log: environment.trafficLog, appVersion: RequestLogExport.appVersion())
    }

    /** Reads every door's live state from myQ, so the cards never show an old state as current; one request per account and never a command. */
    func refreshStatus(force: Bool = false) async {
        guard let environment, session == .signedIn, !catalog.doors.isEmpty, !checkingStatus, throttle.allow(at: Date(), force: force) else { return }
        checkingStatus = true
        defer { checkingStatus = false }
        let result = await environment.refreshStatus()
        if result == .signInRequired { announce(CommandOutcome.signInRequired.dialog(doorName: "")) }
        reload()
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
        await refreshStatus(force: true)
    }

    /** Flips the card at once, sends one command, then watches the door in the background; nothing else on the screen waits or dims. */
    func perform(_ request: DoorRequest, on door: CatalogDoor) async {
        guard let environment, pending[door.identity] == nil else { return }
        let action: DoorAction = request == .close ? .close : .open
        pending[door.identity] = action
        let result = await environment.perform(request, on: door.identity)
        // The card reverts to myQ's answer here, so a refused or failed command never stays shown as moving.
        pending[door.identity] = nil
        reload()
        flash(result.outcome.cardMessage(doorName: door.name), on: door)
        announce(result.dialog)
        if case .accepted = result.outcome { watch(action, on: door, using: environment) }
    }

    private func watch(_ action: DoorAction, on door: CatalogDoor, using environment: GarageEnvironment) {
        followUps[door.identity]?.cancel()
        followUps[door.identity] = Task { [weak self] in
            await environment.followUp(after: action, on: door.identity, onCheck: { [weak self] in await self?.reload() })
            self?.followUps[door.identity] = nil
        }
    }

    /** The card to draw: the instant "sending" card while a tap waits for myQ, otherwise the saved state. */
    func card(for door: CatalogDoor, at date: Date) -> DoorCard {
        if let action = pending[door.identity] { return DoorCard.sending(action) }
        return DoorCard(snapshot: snapshots[door.identity], now: date)
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

/** The home screen from the app design: the moon-and-bats header with Export JSON, then the door cards; everything else lives in Settings behind the moon. */
struct DoorsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = DoorsModel()
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.session == .signedIn {
                    ThemeHeader(openSettings: { showSettings = true }) {
                        if let export = model.requestLogExport {
                            ShareLink(item: export, preview: SharePreview("Whisper Lift request log")) {
                                Label("Export JSON", systemImage: "square.and.arrow.down")
                                    .font(Theme.font(.headline, .bold))
                                    .padding(.horizontal, 18)
                                    .frame(minHeight: 52)
                                    .background(Theme.surface, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.muted, lineWidth: 2))
                            }
                            .foregroundStyle(Theme.text)
                            .accessibilityIdentifier("exportRequestLogButton")
                        }
                    }
                }
                if let problem = model.setupProblem {
                    Text(problem).font(Theme.font(.body)).foregroundStyle(Theme.amber)
                }
                if model.session != .signedIn {
                    SignInPanel(model: model)
                }
                statusLine
                ForEach(model.catalog.doors, id: \.identity) { door in
                    // Ages like "Updated 2 min ago" and the switch to "Last known" happen on their own while the screen is open.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        DoorCardView(
                            door: door, card: model.card(for: door, at: context.date), flash: model.flashes[door.identity],
                            enabled: model.session == .signedIn && !model.busy && model.pending[door.identity] == nil,
                            tap: { card in model.tap(card, on: door) },
                            command: { request in Task { await model.perform(request, on: door) } }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .refreshable { await model.refreshStatus(force: true) }
        .task { await model.refreshStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshStatus() } }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
    }

    @ViewBuilder private var statusLine: some View {
        if model.findingDoors {
            HStack(spacing: 12) {
                ProgressView().tint(Theme.soft)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finding your doors\u{2026}").font(Theme.font(.headline, .bold))
                    Text("Asking myQ which garage doors are on your account.").font(Theme.font(.footnote))
                }
            }
            .accessibilityElement(children: .combine)
        } else if model.checkingStatus {
            HStack(spacing: 8) {
                ProgressView().tint(Theme.soft)
                Text("Checking your doors\u{2026}").font(Theme.font(.footnote))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("checkingStatus")
        } else if let result = model.findResult, model.catalog.doors.isEmpty {
            Text(result).font(Theme.font(.body)).accessibilityIdentifier("findResult")
        }
    }
}

/** The design's sign-in screen: a headline, the myQ button, the privacy note and the advanced token import. */
struct SignInPanel: View {
    let model: DoorsModel
    @State private var token = ""
    @State private var showTokenImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Moon().frame(width: 76, height: 76).frame(maxWidth: .infinity, alignment: .trailing)
            Text("Open your garage with one tap").font(Theme.font(.largeTitle, .bold))
            Text("Sign in with your myQ account to find your doors.").font(Theme.font(.title3))
            if let problem = model.signInProblem {
                Text(problem).font(Theme.font(.body)).foregroundStyle(Theme.amber).accessibilityIdentifier("signInProblem")
            }
            Button { Task { await model.signIn() } } label: {
                Text("Sign in with myQ").font(Theme.font(.title3, .bold)).frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Theme.background)
            .disabled(model.setupProblem != nil || model.busy)
            .accessibilityIdentifier("signInButton")
            Text("You\u{2019}ll sign in on myQ\u{2019}s own page. Your password and verification code go to myQ, not to this app.")
                .font(Theme.font(.footnote))
                .foregroundStyle(Theme.soft)
            TokenImport(model: model, token: $token, isExpanded: $showTokenImport)
            if let message = model.message {
                Text(message).font(Theme.font(.footnote)).accessibilityIdentifier("importMessage")
            }
        }
        .padding(.top, 8)
    }
}

/** The advanced token paste, kept as a fallback to signing in. */
struct TokenImport: View {
    let model: DoorsModel
    @Binding var token: String
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup("Advanced: import a token", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                SecureField("Paste a myQ token", text: $token)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
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
            .padding(.top, 8)
        }
        .font(Theme.font(.body))
        .accessibilityIdentifier("advancedTokenImport")
    }
}

/** The design's Settings page: Siri, the locked-phone note, the request log, finding doors and the account. */
struct SettingsView: View {
    let model: DoorsModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var showTokenImport = false
    @State private var confirmingSignOut = false
    @AppStorage("siriTip.closeDoor.visible") private var showSiriTip = true

    var body: some View {
        NavigationStack {
            Form {
                if !model.catalog.doors.isEmpty {
                    Section {
                        Text(siriExample).accessibilityIdentifier("siriExample")
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
                Section {
                    Text("Siri and the door cards work while the iPhone is locked. Anyone who can use Siri or CarPlay with this phone can open the doors. Sign out to stop that.")
                        .accessibilityIdentifier("lockedPhoneWarning")
                } footer: {
                    #if os(iOS)
                    // Opens Whisper Lift's page in the Shortcuts app, which lists every phrase Siri accepts.
                    ShortcutsLink()
                        .accessibilityIdentifier("shortcutsLink")
                    #endif
                }
                Section {
                    LabeledContent {
                        Text("\(model.requestCount) request\(model.requestCount == 1 ? "" : "s") saved").accessibilityIdentifier("requestCount")
                    } label: {
                        Text("Every request to myQ")
                    }
                    if let traffic = model.traffic {
                        LabeledContent {
                            Text(traffic).accessibilityIdentifier("trafficSummary")
                        } label: {
                            Text("Last myQ exchange")
                        }
                    }
                    if let export = model.requestLogExport {
                        ShareLink(item: export, preview: SharePreview("Whisper Lift request log")) {
                            Label("Export JSON", systemImage: "square.and.arrow.down")
                        }
                    }
                } header: {
                    header("Request log")
                }
                Section {
                    if model.session == .signedIn {
                        Button("Find doors") { Task { await model.findDoors() } }
                            .disabled(model.busy)
                    }
                    if let result = model.findResult {
                        Text(result).accessibilityIdentifier("findResult")
                    }
                } header: {
                    header("Doors")
                }
                Section {
                    // The label is a separate view so the value keeps its own accessibility label.
                    LabeledContent {
                        Text(sessionText).accessibilityIdentifier("sessionStatus")
                    } label: {
                        Text("Status")
                    }
                    if model.session == .signedIn {
                        Button("Sign in to myQ again") { Task { await model.signIn() } }
                            .disabled(model.setupProblem != nil || model.busy)
                        TokenImport(model: model, token: $token, isExpanded: $showTokenImport)
                        if let message = model.message {
                            Text(message).accessibilityIdentifier("importMessage")
                        }
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
                .listRowBackground(Theme.surface)
            }
            .font(Theme.font(.body))
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("settingsDone")
                }
            }
            .confirmationDialog("Sign out and delete?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        await model.signOut()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes everything the app saved: your sign-in, doors, nicknames and request log.")
            }
        }
        .preferredColorScheme(.dark)
    }

    // Bold headline type counts as large text, which clears the contrast audit with margin.
    private func header(_ title: String) -> some View {
        Text(title).font(Theme.font(.headline, .bold)).foregroundStyle(Theme.soft)
    }

    // The design's examples left out the app name and said "garage", which sends Siri to Apple Home; these are the phrases that work.
    private var siriExample: String {
        let names = model.catalog.doors.map { $0.aliases.first ?? $0.name }
        let first = names.first ?? "small door"
        let second = names.dropFirst().first ?? first
        return "Say \u{201C}Open \(first) with Whisper Lift\u{201D} or \u{201C}Close \(second) with Whisper Lift\u{201D}."
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
            Text(door.name).font(Theme.font(.title3, .bold))
            Image(systemName: DoorCardStyle.symbol(card.icon)).font(.system(size: 56, weight: .regular)).accessibilityHidden(true)
            Text(card.title).font(Theme.font(.title2, .bold))
            Text(flash ?? card.detail).font(Theme.font(.body, .semibold))
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding(20)
        .background(DoorCardStyle.fill(card.tone), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var problemCard: some View {
        let accent = DoorCardStyle.accent(card.tone)
        return VStack(alignment: .leading, spacing: 10) {
            Text(door.name).font(Theme.font(.title3, .bold)).foregroundStyle(DoorCardStyle.text)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: DoorCardStyle.symbol(card.icon)).font(.title).foregroundStyle(accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(Theme.font(.title3, .bold)).foregroundStyle(card.tone == .warning ? accent : DoorCardStyle.text)
                    Text(flash ?? card.detail).font(Theme.font(.body)).foregroundStyle(DoorCardStyle.text)
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

/** Maps a card's tone and icon to the theme's colors and SF Symbols; white on each fill keeps at least 4.5:1 contrast. */
enum DoorCardStyle {
    static let background = Theme.surface
    static let text = Theme.text

    static func fill(_ tone: DoorCard.Tone) -> Color {
        switch tone {
        case .closed: Theme.closed
        case .open: Theme.open
        case .moving: Theme.moving
        case .warning, .neutral: Theme.surface
        }
    }

    static func accent(_ tone: DoorCard.Tone) -> Color {
        tone == .warning ? Theme.amber : Theme.soft
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
