import Foundation

extension APIClient {
    /// One page of channels. The server filters by category / search and keeps favorites
    /// (`favoriteIds`) first and through every filter; hidden channels are dropped here.
    func liveChannels(sourceID: String?, categories: [String], favoritesOnly: Bool, search: String,
                      favoriteIDs: [String], offset: Int, limit: Int) async throws -> LiveChannelsPage {
        let body = Self.liveChannelsBody(profileID: profileID, sourceID: sourceID, categories: categories,
            favoritesOnly: favoritesOnly, search: search, favoriteIDs: favoriteIDs, offset: offset, limit: limit)
        return try await send("POST", "/api/live/channels", jsonObject: body, timeout: 60)
    }

    static func liveChannelsBody(profileID: String, sourceID: String?, categories: [String], favoritesOnly: Bool,
                                 search: String, favoriteIDs: [String], offset: Int, limit: Int) -> [String: Any] {
        var body: [String: Any] = ["groupByStation": true, "profileId": profileID, "offset": offset, "limit": limit,
                                   "favoriteIds": favoriteIDs, "favoritesOnly": favoritesOnly]
        if let sourceID { body["sourceId"] = sourceID }
        if !categories.isEmpty { body["categories"] = categories }
        if !search.isEmpty { body["filter"] = search }
        return body
    }

    func epgStatus() async throws -> EPGStatus {
        try await send("GET", "/api/live/epg/status", query: ["profileId": profileID])
    }

    /// Now / next for up to 50 EPG keys.
    func epgNow(_ keys: [String]) async throws -> [EPGNowPlaying] {
        try await send("POST", "/api/live/epg/now", query: ["profileId": profileID], jsonObject: ["channels": keys])
    }

    /// Programmes overlapping `[now + startOffset, + hours]` for each key (every key is in the
    /// answer, with `null` when it has none).
    func epgSchedule(_ keys: [String], startOffsetMinutes: Int, hours: Int) async throws -> [String: [EPGProgram]] {
        let raw: [String: [EPGProgram]?] = try await send("GET", "/api/live/epg/schedule/batch", query: [
            "channels": keys.joined(separator: ","), "hours": String(hours),
            "startOffset": String(startOffsetMinutes), "profileId": profileID,
        ])
        return raw.mapValues { $0 ?? [] }
    }

    /// The profile's `liveTV` favorites and hidden channels, from user settings.
    func liveChannelLists() async throws -> (favorites: [String], hidden: [String]) {
        let live = try await userSettingsObject()["liveTV"] as? [String: Any]
        return (live?["favoriteChannels"] as? [String] ?? [], live?["hiddenChannels"] as? [String] ?? [])
    }

    /// Writes favorites / hidden channels. The settings PUT replaces the whole document, so
    /// it is re-read and only these keys change (as the Expo app does).
    func saveLiveChannelLists(favorites: [String], hidden: [String]) async throws {
        var settings = try await userSettingsObject()
        var live = settings["liveTV"] as? [String: Any] ?? [:]
        live["favoriteChannels"] = favorites
        live["hiddenChannels"] = hidden
        settings["liveTV"] = live
        try await sendRaw("PUT", "\(profilePath)/settings", jsonObject: settings)
    }

    private func userSettingsObject() async throws -> [String: Any] {
        let data = try await sendRaw("GET", "\(profilePath)/settings")
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Opens a channel on the server and returns the URL the engine plays: a direct stream,
    /// or an HLS session (`sessionID`, kept alive with `keepLiveSessionAlive`).
    /// `token=` / `profileUnlock=` ride in the query as on every header-less media URL.
    /// `forceHLS`: an HLS session even when the source is set to direct (`format=hls`).
    func startLive(_ channel: LiveChannel, programTitle: String?, forceHLS: Bool = false,
                   attempt: LivePlaybackAttempt, automatic: Bool = false) async throws -> LiveTune {
        let start = try await openLiveStart(channel, programTitle: programTitle, forceHLS: forceHLS, target: "native", attempt: attempt, automatic: automatic)
        do {
            let isDirect = start.isDirect == true
            guard let path = isDirect ? start.streamUrl : start.playlistUrl, !path.isEmpty,
                  isDirect ? start.sessionId == nil : (start.sessionId.map(KidsLiveOpened.validSession) == true &&
                    URLComponents(string: path)?.path == "/video/hls/\(start.sessionId!)/stream.m3u8") else {
                throw APIError.notReady("The server did not return a stream for this channel")
            }
            return LiveTune(url: try mediaURL(apiPath: path, context: attempt.context), sessionID: isDirect ? nil : start.sessionId,
                stremioStreamIndex: start.stremioStreamIndex, stremioStreamIndexes: start.stremioStreamIndexes)
        } catch {
            let cleanup = Task { try await self.retireLiveStart(start, context: attempt.context) }
            do { try await cleanup.value } catch { attempt.stopUnconfirmed() }
            throw error
        }
    }

    func openLiveStart(_ channel: LiveChannel, programTitle: String?, forceHLS: Bool,
                       target: String, attempt: LivePlaybackAttempt, automatic: Bool = false) async throws -> LiveStart {
        var original = liveStartQuery(channel, programTitle: programTitle)
        original["target"] = target
        original["profileId"] = attempt.context.profileID
        original["clientId"] = attempt.context.clientID
        if forceHLS { original["format"] = "hls" }
        let query = original
        return try await attempt.open(channel, automaticIntent: automatic,
            confirm: { challenge, deadline in await attempt.confirmRecording(challenge, deadline: deadline) },
            fetch: { id, confirmation, automatic in
                try self.requireSourceContext(attempt.context)
                var values = query
                values["playAttemptId"] = id
                values["automaticRetry"] = String(automatic)
                var request = try Self.liveStartRequest(context: attempt.context, query: values, confirmation: confirmation)
                request.timeoutInterval = 30
                let data = try await self.sendOriginalSourceAction(request)
                do { return try self.decoder.decode(LiveStart.self, from: data) }
                catch {
                    struct Receipt: Decodable { let sessionId: String }
                    if let receipt = try? self.decoder.decode(Receipt.self, from: data), KidsLiveOpened.validSession(receipt.sessionId) {
                        let cleanup = Task { try await self.stopLiveSessionStrict(receipt.sessionId, context: attempt.context) }
                        do { try await cleanup.value } catch { attempt.stopUnconfirmed() }
                    }
                    throw error
                }
            }, retire: { reply in try await self.retireLiveStart(reply, context: attempt.context) })
    }

    static func liveStartRequest(context: SourceActionContext, query: [String: String], confirmation: String?) throws -> URLRequest {
        var request = try context.request("GET", path: "/api/live/hls/start")
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.notReady("The channel address is unavailable")
        }
        var values = query
        values["profileId"] = context.profileID
        values["clientId"] = context.clientID
        components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.url = components.url
        if let confirmation { request.setValue(confirmation, forHTTPHeaderField: "X-Live-Recording-Confirmation") }
        return request
    }

    func retireLiveStart(_ reply: LiveStart, context: SourceActionContext) async throws {
        if let id = reply.sessionId, KidsLiveOpened.validSession(id) { try await stopLiveSessionStrict(id, context: context) }
    }

    func keepLiveSessionAliveStrict(_ sessionID: String, context: SourceActionContext, paused: Bool? = nil) async throws {
        try requireSourceContext(context)
        var request = try context.request("POST", path: "/api/video/hls/\(Self.segment(sessionID))/keepalive")
        request.timeoutInterval = 10
        if let paused, let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "paused", value: String(paused))]
            request.url = components.url
        }
        _ = try await sendOriginalSourceAction(request)
        try requireSourceContext(context)
    }

    /// The `/api/live/hls/start` query for `channel`.
    func liveStartQuery(_ channel: LiveChannel, programTitle: String?) -> [String: String] {
        var q = [
            "url": channel.url, "target": "native", "profileId": profileID,
            "mediaType": "channel", "title": programTitle ?? channel.name,
            "channelId": channel.playbackId ?? channel.id, "channelName": channel.name,
            "liveSourceUrl": channel.url,
            // A transmuxed direct stream (a Stremio HLS channel) as MPEG-TS, not fragmented MP4:
            // the engine leaves a live source seekable, and on a seekable fragmented MP4 FFmpeg
            // reads fragment after fragment for an index and never finishes opening.
            "container": "ts",
        ]
        if let profileName, !profileName.isEmpty { q["profileName"] = profileName }
        if let v = channel.sourceId { q["sourceId"] = v; q["liveSourceId"] = v }
        if let v = channel.tvgId { q["itemId"] = v }
        if let v = channel.tvgName { q["tvgName"] = v }
        if let v = channel.group { q["category"] = v }
        if let v = channel.logo { q["liveChannelLogo"] = v }
        if let v = channel.stremioStreamIndex, v >= 0 { q["stremioStreamIndex"] = String(v) }
        return q
    }

    /// The streams a Stremio channel's addon lists for it, for Choose Source.
    func liveStremioStreams(_ channel: LiveChannel, timeout: TimeInterval = 60) async throws -> [LiveStremioStream] {
        struct Response: Decodable { let streams: [LiveStremioStream]? }
        let response: Response = try await send("GET", "/api/live/stremio/streams",
                                                query: ["url": channel.url, "profileId": profileID], timeout: timeout)
        return response.streams ?? []
    }

    /// The server's stable remote-access identity, which Live TV's remembered HLS choice is
    /// kept under (`LiveHLSPreference`).
    func serverIdentity() async throws -> String? {
        struct Identity: Decodable { let serverId: String? }
        let identity: Identity = try await send("GET", "/api/remote-access/identity", promptOnLock: false, timeout: 5)
        return identity.serverId
    }

    func keepLiveSessionAlive(_ sessionID: String) async {
        _ = try? await sendRaw("POST", "/api/video/hls/\(Self.segment(sessionID))/keepalive", promptOnLock: false, timeout: 10)
    }

    func stopLiveSession(_ sessionID: String) async {
        _ = try? await sendRaw("POST", "/api/video/hls/\(Self.segment(sessionID))/stop", promptOnLock: false, timeout: 10)
    }

    /// A server-relative media path (`/live/stream?…`, `/video/hls/…`) under `/api`, with the
    /// session token and profile unlock added to its query.
    func mediaURL(apiPath: String, context: SourceActionContext? = nil) throws -> URL {
        if let context {
            guard let supplied = URLComponents(string: apiPath), supplied.scheme == nil, supplied.host == nil,
                  supplied.path.hasPrefix("/video/") || supplied.path.hasPrefix("/live/") else {
                throw APIError.notReady("The server returned an unsupported live address")
            }
            let original = try context.request("GET", path: "/api" + supplied.path)
            guard let raw = original.url, var components = URLComponents(url: raw, resolvingAgainstBaseURL: false) else {
                throw APIError.notReady("The live address is unavailable")
            }
            var query = (supplied.queryItems ?? []).filter { !["token", "profileId", "profileUnlock", "clientId"].contains($0.name) }
            query += [URLQueryItem(name: "profileId", value: context.profileID), URLQueryItem(name: "clientId", value: context.clientID)]
            if let auth = original.value(forHTTPHeaderField: "Authorization"), auth.hasPrefix("Bearer ") {
                query.append(URLQueryItem(name: "token", value: String(auth.dropFirst(7))))
            }
            if let unlock = original.value(forHTTPHeaderField: "X-Profile-Unlock") { query.append(URLQueryItem(name: "profileUnlock", value: unlock)) }
            components.queryItems = query
            guard let url = components.url else { throw APIError.notReady("The live address is unavailable") }
            return url
        }
        let parts = apiPath.split(separator: "?", maxSplits: 1).map(String.init)
        var extra: [String] = []
        if let token { extra.append("token=\(Self.segment(token))") }
        if let unlock = profileUnlocks.token(for: profileID) { extra.append("profileUnlock=\(Self.segment(unlock))") }
        let query = ([parts.count > 1 ? parts[1] : nil] + extra).compactMap { $0 }.filter { !$0.isEmpty }
        return url("/api" + parts[0], encodedQuery: query.joined(separator: "&"))
    }
}
