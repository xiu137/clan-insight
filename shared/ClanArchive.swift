import Foundation

struct ClanArchive: Codable, Sendable {
    var format = "coc-clan-archive"
    var schemaVersion = 1
    var clanTag: String
    var observations: [ClanObservation] = []

    init(clanTag: String) { self.clanTag = clanTag.uppercased() }

    static func normalizedTag(_ text: String) throws -> String {
        let value = "#" + text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.range(of: #"^#[A-Z0-9]{3,15}$"#, options: .regularExpression) != nil else {
            throw ClanDataError.invalid("Invalid clan tag")
        }
        return value
    }

    static func decode(_ data: Data, now: Date = .now) throws -> ClanArchive {
        guard data.count <= 32 * 1024 * 1024 else { throw ClanDataError.invalid("Clan archive exceeds 32 MB") }
        let root = try JSONDecoder().decode(ClanJSON.self, from: data)
        guard root["schemaVersion"].int == 1 else { throw ClanDataError.invalid("Unsupported clan archive version") }
        if root["format"].string == "coc-clan-api-research-archive" {
            guard let tag = root["clanTag"].string else { throw ClanDataError.invalid("Missing clan tag") }
            var result = ClanArchive(clanTag: try normalizedTag(tag))
            let rows = root["observations"].array ?? []
            guard rows.count <= 100_000 else { throw ClanDataError.invalid("Too many observations") }
            var incoming: [ClanObservation] = []
            for row in rows where row["httpStatus"].int == 200 {
                guard row["method"].string == "GET", let path = row["path"].string,
                      let route = ClanAPIKind.route(path), let date = row["receivedAt"].date else { continue }
                let observation = try ClanObservation(kind: route.0, subject: route.1, observedAt: date,
                    sourcePath: path, serverDate: row["responseMetadata"]["Date"].string,
                    payload: row["payload"])
                incoming.append(observation)
            }
            try result.merge(incoming, now: now)
            guard !result.observations.isEmpty else { throw ClanDataError.invalid("No supported clan observations") }
            return result
        }
        guard root["format"].string == "coc-clan-archive" else { throw ClanDataError.invalid("This is not a clan archive") }
        let archive = try ClanDate.decoder().decode(ClanArchive.self, from: data)
        var result = ClanArchive(clanTag: try normalizedTag(archive.clanTag))
        try result.merge(archive.observations, now: now)
        return result
    }

    func encoded() throws -> Data { try ClanDate.encoder(pretty: true).encode(self) }

    mutating func merge(_ incoming: [ClanObservation], now: Date = .now) throws {
        guard observations.count + incoming.count <= 100_000 else { throw ClanDataError.invalid("Too many observations") }
        var byID = Dictionary(observations.map { ($0.id, $0) }, uniquingKeysWith: { old, new in
            old.confirmedAt >= new.confirmedAt ? old : new
        })
        for raw in incoming {
            guard raw.observedAt.timeIntervalSince1970.isFinite, raw.confirmedAt.timeIntervalSince1970.isFinite,
                  raw.confirmedAt >= raw.observedAt, raw.confirmedAt <= now.addingTimeInterval(300),
                  raw.observedAt >= Date(timeIntervalSince1970: 1_000_000_000) else {
                throw ClanDataError.invalid("Invalid or future observation time")
            }
            let value = try ClanObservation(kind: raw.kind, subject: raw.subject, observedAt: raw.observedAt,
                confirmedAt: raw.confirmedAt, sourcePath: raw.sourcePath, serverDate: raw.serverDate,
                cacheMaxAge: raw.cacheMaxAge, payload: raw.payload)
            if [.clan, .currentwar, .cwlgroup, .warlog].contains(value.kind), value.subject != clanTag {
                throw ClanDataError.invalid("Archive contains a different clan")
            }
            if value.kind == .clan {
                guard value.payload["tag"].string?.uppercased() == clanTag,
                      let members = value.payload["memberList"].array,
                      value.payload["members"].int == members.count, members.count <= 50,
                      members.compactMap(ClanMemberInfo.init).count == members.count,
                      Set(members.compactMap { $0["tag"].string?.uppercased() }).count == members.count else {
                    throw ClanDataError.invalid("Incomplete clan roster; membership was not changed")
                }
            }
            if value.kind == .player, value.payload["tag"].string?.uppercased() != value.subject {
                throw ClanDataError.invalid("Player observation tag mismatch")
            }
            if [.currentwar, .cwlwar].contains(value.kind), value.payload["state"].string != "notInWar",
               ClanWarRecord(observation: value, clanTag: clanTag) == nil {
                throw ClanDataError.invalid("War observation does not contain this clan")
            }
            if let prior = byID[value.id], prior.confirmedAt > value.confirmedAt { continue }
            byID[value.id] = value
        }
        // A full final war is immutable against stale/incomplete imports. Keep one raw winner
        // per actual war; membership/opt changes remain an ordered observation history.
        var wars: [String: (ClanObservation, ClanWarRecord)] = [:]
        var retained: [ClanObservation] = []
        for observation in byID.values.sorted(by: { $0.observedAt < $1.observedAt }) {
            guard let war = ClanWarRecord(observation: observation, clanTag: clanTag) else {
                retained.append(observation); continue
            }
            if let prior = wars[war.id] {
                let oldRank = (prior.1.isSettled ? 4 : prior.1.complete ? 2 : 0) + (prior.1.isEnded ? 1 : 0)
                let newRank = (war.isSettled ? 4 : war.complete ? 2 : 0) + (war.isEnded ? 1 : 0)
                if newRank < oldRank || newRank == oldRank && prior.0.confirmedAt > observation.confirmedAt { continue }
            }
            wars[war.id] = (observation, war)
        }
        retained += wars.values.map(\.0)
        let ordered = retained.sorted { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt < $1.observedAt }
        var compact: [ClanObservation] = [], last: [String: Int] = [:]
        for observation in ordered {
            let key = observation.kind.rawValue + observation.subject
            if let index = last[key], compact[index].payload == observation.payload,
               observation.observedAt.timeIntervalSince(compact[index].confirmedAt) <= 1800,
               ![.currentwar, .cwlwar].contains(observation.kind) {
                compact[index].confirmedAt = max(compact[index].confirmedAt, observation.confirmedAt)
            } else {
                last[key] = compact.count; compact.append(observation)
            }
        }
        observations = compact
    }
}

struct ClanRosterObservation: Hashable, Sendable {
    var date: Date
    var members: [ClanMemberInfo]
}

struct ClanOptObservation: Hashable, Sendable {
    var date: Date
    var value: ClanOptIn
    var confirmedThrough: Date? = nil
}

struct ClanMemberHistory: Identifiable, Hashable, Sendable {
    var info: ClanMemberInfo
    var isCurrent: Bool
    var membership: [ClanMembershipEvent]
    var opt: [ClanOptObservation]
    var lastOwnAttackAt: Date?
    var activityCheckedAt: Date?
    var activityWindowContainsOwnAttack = false
    var id: String { info.tag }
}

enum ClanMembershipKind: String, Hashable, Sendable { case baselinePresent, baselineOutside, joined, left, returned }

struct ClanMembershipEvent: Hashable, Identifiable, Sendable {
    var kind: ClanMembershipKind
    var date: Date
    var after: Date?
    var id: String { kind.rawValue + ":" + String(date.timeIntervalSince1970) }
}

/// Immutable, rebuilt off the main actor after imports/sync. Never interprets HTTP errors as data.
struct ClanDataset: Sendable {
    var clanTag: String
    var clanName: String
    var latestRosterAt: Date?
    var members: [ClanMemberHistory]
    var rosters: [ClanRosterObservation]
    var wars: [ClanWarRecord]
    var latestObservationAt: Date?
    var currentWarState: String?
    var privateWarLog: Bool?

    init(_ archive: ClanArchive) {
        clanTag = archive.clanTag; clanName = archive.clanTag
        rosters = []; wars = []; members = []
        var info: [String: ClanMemberInfo] = [:]
        var opt: [String: [ClanOptObservation]] = [:]
        var activity: [String: Date] = [:], activityRead: [String: Date] = [:]
        var activityCovered: [String: Bool] = [:]
        var warSeasons: [String: (String, Int)] = [:]
        let observations = archive.observations.sorted { $0.observedAt < $1.observedAt }
        latestObservationAt = observations.map(\.confirmedAt).max()
        for observation in observations where observation.kind == .cwlgroup {
            let body = observation.payload
            guard let season = body["season"].string else { continue }
            for (round, item) in (body["rounds"].array ?? []).enumerated() {
                for tag in item["warTags"].array?.compactMap(\.string) ?? [] where tag != "#0" {
                    warSeasons[tag.uppercased()] = (season, round + 1)
                }
            }
        }
        for observation in observations {
            let body = observation.payload
            switch observation.kind {
            case .clan:
                let rows = (body["memberList"].array ?? []).compactMap(ClanMemberInfo.init)
                clanName = body["name"].string ?? clanName
                privateWarLog = body["isWarLogPublic"].bool.map { !$0 }
                for row in rows { info[row.tag] = row }
                rosters.append(ClanRosterObservation(date: observation.observedAt, members: rows))
                if observation.confirmedAt > observation.observedAt {
                    rosters.append(ClanRosterObservation(date: observation.confirmedAt, members: rows))
                }
            case .player:
                if let row = ClanMemberInfo(body), info[row.tag] == nil { info[row.tag] = row }
                let value = ClanOptIn(rawValue: body["warPreference"].string ?? "") ?? .unknown
                if value != .unknown {
                    opt[observation.subject, default: []].append(ClanOptObservation(date: observation.observedAt, value: value,
                        confirmedThrough: observation.confirmedAt))
                    if observation.confirmedAt > observation.observedAt {
                        opt[observation.subject, default: []].append(ClanOptObservation(date: observation.confirmedAt, value: value))
                    }
                }
            case .battlelog:
                if observation.confirmedAt >= (activityRead[observation.subject] ?? .distantPast) {
                    activityRead[observation.subject] = observation.confirmedAt
                    activityCovered[observation.subject] = (body["items"].array ?? []).contains {
                        guard $0["attack"].bool == true, let date = $0["battleTimestamp"].date else { return false }
                        return date <= observation.confirmedAt.addingTimeInterval(300)
                    }
                }
                for battle in body["items"].array ?? [] where battle["attack"].bool == true {
                    guard let date = battle["battleTimestamp"].date, date <= observation.confirmedAt.addingTimeInterval(300) else { continue }
                    activity[observation.subject] = max(activity[observation.subject] ?? .distantPast, date)
                }
            case .currentwar:
                currentWarState = body["state"].string
                fallthrough
            case .cwlwar:
                let context = warSeasons[observation.subject]
                if let war = ClanWarRecord(observation: observation, clanTag: archive.clanTag,
                                           season: context?.0, round: context?.1) {
                    wars.append(war)
                    for member in war.members where info[member.info.tag] == nil { info[member.info.tag] = member.info }
                }
            case .cwlgroup:
                for clan in body["clans"].array ?? [] where clan["tag"].string?.uppercased() == archive.clanTag {
                    for raw in clan["members"].array ?? [] {
                        if let member = ClanMemberInfo(raw), info[member.tag] == nil { info[member.tag] = member }
                    }
                }
            case .warlog: break // Historical summaries must never create zero-attack people.
            }
        }
        rosters.sort { $0.date < $1.date }
        latestRosterAt = rosters.last?.date
        let latestTags = Set(rosters.last?.members.map(\.tag) ?? [])
        // The latest complete roster owns name/role; external player roles cannot grant exemptions.
        for member in rosters.last?.members ?? [] { info[member.tag] = member }
        for (tag, member) in info {
            var events: [ClanMembershipEvent] = []
            var previous: Bool?, lastDate: Date?, everPresent = false
            for roster in rosters {
                let present = roster.members.contains { $0.tag == tag }
                if previous == nil {
                    events.append(ClanMembershipEvent(kind: present ? .baselinePresent : .baselineOutside, date: roster.date))
                } else if present != previous {
                    let kind: ClanMembershipKind = present ? (everPresent ? .returned : .joined) : .left
                    events.append(ClanMembershipEvent(kind: kind, date: roster.date, after: lastDate))
                }
                if present { everPresent = true }
                previous = present; lastDate = roster.date
            }
            let history = (opt[tag] ?? []).sorted { $0.date < $1.date }
            members.append(ClanMemberHistory(info: member, isCurrent: latestTags.contains(tag), membership: events,
                opt: history, lastOwnAttackAt: activity[tag], activityCheckedAt: activityRead[tag],
                activityWindowContainsOwnAttack: activityCovered[tag] ?? false))
        }
        members.sort { $0.info.name.localizedStandardCompare($1.info.name) == .orderedAscending }
        wars.sort { $0.startsAt > $1.startsAt }
    }
}
