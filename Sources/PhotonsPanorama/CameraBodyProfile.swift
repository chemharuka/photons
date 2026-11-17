import Foundation
import PhotonsLocalization

/// An immutable snapshot of mechanical travel in the body's unrotated right/up coordinates.
public struct CameraBodyProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let travel: PanoramaShiftRange
    public static let maximumTravel = 150.0

    public init(id: UUID = UUID(), name: String, travel: PanoramaShiftRange) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw PanoramaFailure(L10n.tr("cameraBodies.invalidName")) }
        guard [travel.left, travel.right, travel.up, travel.down].allSatisfy({
            $0.isFinite && (0...Self.maximumTravel).contains($0)
        }) else { throw PanoramaFailure(L10n.tr("cameraBodies.invalidTravel")) }
        self.id = id; self.name = name; self.travel = travel
    }

    private enum CodingKeys: String, CodingKey { case id, name, travel }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      name: values.decode(String.self, forKey: .name),
                      travel: values.decode(PanoramaShiftRange.self, forKey: .travel))
    }
}

public struct CameraBodyCatalog {
    public var custom: [PanoramaCameraBody]
    public var issues: [String]
    public var bodies: [PanoramaCameraBody] { PanoramaCameraBody.allCases + custom }
}

/// Built-ins live in code, never in the writable directory. All mutations reject them.
public struct CameraBodyStore {
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photons/CameraBodies", isDirectory: true)
    }
    public func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".photonscamera") }

    public func catalog() -> CameraBodyCatalog {
        guard FileManager.default.fileExists(atPath: directory.path) else { return .init(custom: [], issues: []) }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
                .filter { $0.pathExtension == "photonscamera" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var bodies: [PanoramaCameraBody] = [], issues: [String] = []
            for file in files {
                do {
                    let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard info.isRegularFile == true, let size = info.fileSize, (1...65_536).contains(size) else {
                        throw PanoramaFailure(L10n.tr("cameraBodies.invalidFile"))
                    }
                    let body = try JSONDecoder().decode(PanoramaCameraBody.self, from: Data(contentsOf: file))
                    guard case .custom(let profile) = body, file.lastPathComponent == url(for: profile.id).lastPathComponent else {
                        throw PanoramaFailure(L10n.tr("cameraBodies.invalidFile"))
                    }
                    bodies.append(body)
                } catch { issues.append("\(file.lastPathComponent): \(error.localizedDescription)") }
            }
            bodies.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return .init(custom: bodies, issues: issues)
        } catch { return .init(custom: [], issues: [error.localizedDescription]) }
    }

    @discardableResult public func save(_ body: PanoramaCameraBody) throws -> URL {
        guard case .custom(let profile) = body else { throw PanoramaFailure(L10n.tr("cameraBodies.builtInReadOnly")) }
        let duplicate = catalog().bodies.contains {
            $0.id != body.id && $0.name.compare(body.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard !duplicate else { throw PanoramaFailure(L10n.tr("cameraBodies.duplicateName")) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(body)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = url(for: profile.id)
        try data.write(to: target, options: .atomic)
        return target
    }

    public func delete(_ body: PanoramaCameraBody) throws {
        guard case .custom(let profile) = body else { throw PanoramaFailure(L10n.tr("cameraBodies.builtInReadOnly")) }
        try FileManager.default.removeItem(at: url(for: profile.id))
    }
}
