import CoreTransferable
import Foundation
import GarageDoorKit
import UniformTypeIdentifiers

/** The myQ request log as a JSON file, built when the share sheet asks for it so it always holds the latest entries. */
struct RequestLogExport: Transferable {
    let log: TrafficLog
    let appVersion: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { export in
            let exportedAt = Date()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(TrafficExport.fileName(exportedAt: exportedAt), isDirectory: false)
            try TrafficExport.json(try export.log.read(), exportedAt: exportedAt, appVersion: export.appVersion).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    /** The marketing version and build number, for example "0.0.1 (1)". */
    static func appVersion(_ bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }
}
