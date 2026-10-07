import GarageTilesKit
import SwiftUI
import WidgetKit

/** Phase 0 diagnostics: shows whether the App Group is readable and which process wrote the last tap. */
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: CounterSnapshot?
    @State private var failure: (reason: CounterUnavailable, detail: String)?

    private let appGroup = AppGroup.identifier()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Identifier", appGroup ?? "Missing from Info.plist", id: "appGroupIdentifier")
                        .accessibilityLabel(appGroup == nil ? "App Group identifier missing" : "App Group identifier")
                    row("Status", failure?.reason.headline ?? "Readable", id: "appGroupStatus")
                    if let failure {
                        Text("\(failure.reason.guidance) (\(failure.detail))").font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    header("App Group")
                }
                Section {
                    row("Total", snapshot.map { "\($0.total)" } ?? "–", id: "totalValue")
                    ForEach(SpikeTile.allCases, id: \.self) { tile in
                        row(tile.title, snapshot.map { "\($0.taps(for: tile))" } ?? "–", id: "tileValue-\(tile.rawValue)")
                    }
                    row("Last tile", snapshot?.lastTile?.title ?? "–", id: "lastTileValue")
                    row("Last tap", snapshot?.lastTapAt?.formatted(date: .abbreviated, time: .standard) ?? "–", id: "lastTapValue")
                    row("Last writer", writerDescription, id: "lastWriterValue")
                } header: {
                    header("Counter")
                }
                Section {
                    ForEach(SpikeTile.allCases, id: \.self) { tile in
                        Button("Bump \(tile.title) from the app") { bump(tile) }
                    }
                    Button("Reload widgets") { WidgetCenter.shared.reloadAllTimelines() }
                    Button("Refresh") { refresh() }
                } footer: {
                    Text("This Phase 0 build uses a mock counter only. It holds no myQ credentials and cannot control a garage door.")
                        .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Whisper Lift Spike")
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    // Values are separate Text views with identifiers so the UI tests can read them, in primary text because the default secondary gray fails the contrast audit.
    private func row(_ title: String, _ value: String, id: String) -> some View {
        LabeledContent {
            Text(value).foregroundStyle(.primary).accessibilityIdentifier(id)
        } label: {
            Text(title)
        }
    }

    // Section headers in bold headline type count as large text, so they clear the contrast audit with margin instead of barely passing on some runs.
    private func header(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.primary)
    }

    private var writerDescription: String {
        snapshot?.writerDescription(currentBundle: Bundle.main.bundleIdentifier) ?? "–"
    }

    private func refresh() {
        do {
            snapshot = try AppGroup.counterStore().read()
            failure = nil
        } catch {
            snapshot = nil
            failure = (CounterUnavailable(error), String(describing: error))
        }
    }

    private func bump(_ tile: SpikeTile) {
        do {
            snapshot = try AppGroup.counterStore().increment(tile: tile, writer: Bundle.main.bundleIdentifier)
            failure = nil
            WidgetCenter.shared.reloadTimelines(ofKind: SpikeWidgetKind.counter)
        } catch {
            failure = (CounterUnavailable(error), String(describing: error))
        }
    }
}

#Preview {
    ContentView()
}
