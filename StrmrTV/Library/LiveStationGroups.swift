import Foundation

/// Presentation of exact server station identities, never a name/URL guess.
enum LiveStationGroups {
    struct Member: Identifiable {
        let channel: LiveChannel
        var id: String { LiveStationGroups.channelKey(channel) }
    }
    struct Section: Identifiable {
        let id: String
        let stationID: String?
        let name: String
        var channels: [LiveChannel]
        let reportedVariants: Int?
        var members: [Member] { channels.map { Member(channel: $0) } }
        var scope: String {
            if let total = reportedVariants, total > channels.count {
                return "\(channels.count) of \(total) source variants loaded"
            }
            return "\(channels.count) source variants loaded"
        }
    }
    static func channelKey(_ channel: LiveChannel) -> String {
        let source = channel.sourceId ?? ""
        return "channel:\(source.utf8.count):\(source):\(channel.id)"
    }
    static func stationID(_ channel: LiveChannel) -> String? {
        guard let value = channel.stationId,
              value.range(of: "^station:[0-9a-f]{24}$", options: .regularExpression) != nil else { return nil }
        return value
    }
    static func sections(_ channels: [LiveChannel]) -> [Section] {
        var groups: [Section] = []
        var positions: [String: Int] = [:]
        var seen = Set<String>()
        for channel in channels where seen.insert(channelKey(channel)).inserted {
            let station = stationID(channel)
            let key = station.map { "station-group:\($0)" } ?? channelKey(channel)
            if let position = positions[key] {
                let old = groups[position]
                groups[position] = Section(id: old.id, stationID: old.stationID, name: old.name,
                    channels: old.channels + [channel], reportedVariants: max(old.reportedVariants ?? 0, channel.stationVariants ?? 0))
            } else {
                positions[key] = groups.count
                groups.append(Section(id: key, stationID: station, name: channel.stationName ?? channel.name,
                    channels: [channel], reportedVariants: channel.stationVariants))
            }
        }
        // A station with one known source needs no separate heading. Adjacent
        // standalone entries retain the existing multi-column channel grid.
        var result: [Section] = []
        for group in groups {
            let header = group.stationID != nil && (group.channels.count > 1 || (group.reportedVariants ?? 0) > 1)
            if header { result.append(group) }
            else if let last = result.indices.last, result[last].stationID == nil {
                result[last].channels += group.channels
            } else {
                result.append(Section(id: "channels:\(channelKey(group.channels[0]))", stationID: nil,
                    name: "", channels: group.channels, reportedVariants: nil))
            }
        }
        return result
    }
}

extension LiveChannel {
    var presentationKey: String { LiveStationGroups.channelKey(self) }
}
