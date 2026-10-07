import AppIntents
import GarageTilesKit
import SwiftUI
import WidgetKit

struct SpikeEntry: TimelineEntry {
    let date: Date
    let tile: SpikeTile
    let snapshot: CounterSnapshot?
    let failure: CounterUnavailable?
}

struct SpikeProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SpikeEntry {
        SpikeEntry(date: .now, tile: .alpha, snapshot: .empty, failure: nil)
    }

    func snapshot(for configuration: SpikeWidgetConfigurationIntent, in context: Context) async -> SpikeEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SpikeWidgetConfigurationIntent, in context: Context) async -> Timeline<SpikeEntry> {
        // Taps reload the timeline explicitly, so no periodic refresh is requested.
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: SpikeWidgetConfigurationIntent) -> SpikeEntry {
        let tile = configuration.tile.tile
        do {
            return SpikeEntry(date: .now, tile: tile, snapshot: try AppGroup.counterStore().read(), failure: nil)
        } catch {
            return SpikeEntry(date: .now, tile: tile, snapshot: nil, failure: CounterUnavailable(error))
        }
    }
}

struct SpikeCounterWidgetView: View {
    let entry: SpikeEntry

    var body: some View {
        Button(intent: IncrementCounterIntent(tile: SpikeTileAppEnum(entry.tile))) {
            VStack(alignment: .leading, spacing: 4) {
                Label(entry.tile.title, systemImage: entry.tile.symbolName)
                    .font(.headline)
                    .foregroundStyle(entry.tile == .alpha ? Color.orange : Color.teal)
                Spacer(minLength: 0)
                if let snapshot = entry.snapshot {
                    Text("\(snapshot.taps(for: entry.tile))")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("Total \(snapshot.total)")
                        .font(.caption)
                    if let tappedAt = snapshot.lastTapAt {
                        Text(tappedAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let reason = entry.failure ?? .unexpected
                    Text(reason.headline)
                        .font(.subheadline.weight(.semibold))
                    Text(reason.guidance)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) {
            (entry.tile == .alpha ? Color.orange : Color.teal).opacity(0.18)
        }
    }
}

struct SpikeCounterWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SpikeWidgetKind.counter, intent: SpikeWidgetConfigurationIntent.self, provider: SpikeProvider()) { entry in
            SpikeCounterWidgetView(entry: entry)
        }
        .configurationDisplayName("Spike Counter")
        .description("Phase 0 test tile. Tap to bump a shared counter; it does not control a garage door.")
        .supportedFamilies([.systemSmall])
    }
}

#Preview(as: .systemSmall) {
    SpikeCounterWidget()
} timeline: {
    SpikeEntry(date: .now, tile: .alpha, snapshot: CounterSnapshot(total: 5, tapsByTile: [.alpha: 3, .bravo: 2], lastTile: .alpha, lastTapAt: .now, lastWriter: nil), failure: nil)
    SpikeEntry(date: .now, tile: .bravo, snapshot: nil, failure: .protectedData)
}
