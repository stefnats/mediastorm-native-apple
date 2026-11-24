import Foundation

struct PictureStyleState: Decodable, Equatable {
    let profileId: String
    let supported: Bool
    let enabled: Bool
    let minimumSamples: Int
    let maxSamples: Int
    let posterSamples: Int
    let backdropSamples: Int

    func validated(profileID: String) throws -> Self {
        guard profileId == profileID, supported, minimumSamples == 3, maxSamples == 128,
              (0...maxSamples).contains(posterSamples), (0...maxSamples).contains(backdropSamples),
              posterSamples + backdropSamples <= maxSamples else { throw PersonalTasteError.unavailable }
        return self
    }
}

enum PictureStyleWire {
    static func body(enabled: Bool?, reset: Bool) throws -> [String: Any] {
        if reset, enabled == nil { return ["reset": true] }
        if !reset, let enabled { return ["enabled": enabled] }
        throw PersonalTasteError.unavailable
    }

    static func confirmed(_ value: PictureStyleState, enabled: Bool?, reset: Bool) throws -> PictureStyleState {
        _ = try body(enabled: enabled, reset: reset)
        guard reset ? !value.enabled && value.posterSamples == 0 && value.backdropSamples == 0
                    : value.enabled == enabled else { throw PersonalTasteError.unavailable }
        return value
    }
}

extension APIClient {
    func readPictureStyle(context: SourceActionContext) async throws -> PictureStyleState {
        try Task.checkCancellation(); try requireSourceContext(context)
        let request = try context.request("GET", path: PersonalTasteWire.path(context) + "/artwork-learning")
        let raw = try await sendOriginalSourceAction(request)
        try Task.checkCancellation(); try requireSourceContext(context)
        return try decoder.decode(PictureStyleState.self, from: raw).validated(profileID: context.profileID)
    }

    func updatePictureStyle(enabled: Bool?, reset: Bool, context: SourceActionContext) async throws -> PictureStyleState {
        try Task.checkCancellation(); try requireSourceContext(context)
        let request = try context.request("PUT", path: PersonalTasteWire.path(context) + "/artwork-learning",
                                          body: PictureStyleWire.body(enabled: enabled, reset: reset))
        let raw = try await sendOriginalSourceAction(request)
        try Task.checkCancellation(); try requireSourceContext(context)
        let value = try decoder.decode(PictureStyleState.self, from: raw).validated(profileID: context.profileID)
        return try PictureStyleWire.confirmed(value, enabled: enabled, reset: reset)
    }
}
