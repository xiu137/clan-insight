import Foundation
import CryptoKit

/// Shared Web/iOS facts. Dates are Unix milliseconds; raw API evidence stays in archives.
struct ClanSnapshot: Codable, Sendable {
    static let modelVersion = "clan-v1-policy-v2"
    static let maximumBytes = 16 * 1024 * 1024
    var format = "coc-clan-snapshot"
    var schemaVersion = 1
    var modelVersion = Self.modelVersion
    var timestampUnit = "unix-ms"
    var clanTag: String
    var clanName: String
    var latestRosterAt: Date?
    var latestObservationAt: Date?
    var currentWarState: String?
    var privateWarLog: Bool?
    var members: [Member]
    var wars: [ClanWarRecord]

    struct Membership: Codable, Sendable {
        var kind: String
        var date: Date
        var after: Date?
    }
    struct Intent: Codable, Sendable {
        var date: Date
        var value: ClanOptIn
        var confirmedThrough: Date?
    }
    struct Member: Codable, Sendable {
        var info: ClanMemberInfo
        var isCurrent: Bool
        var membership: [Membership]
        var opt: [Intent]
        var lastOwnAttackAt: Date?
        var activityCheckedAt: Date?
        var activityWindowContainsOwnAttack: Bool

        init(_ source: ClanMemberHistory) {
            info = source.info; isCurrent = source.isCurrent
            membership = source.membership.map { Membership(kind: $0.kind.rawValue, date: $0.date, after: $0.after) }
            opt = source.opt.map { Intent(date: $0.date, value: $0.value, confirmedThrough: $0.confirmedThrough) }
            lastOwnAttackAt = source.lastOwnAttackAt; activityCheckedAt = source.activityCheckedAt
            activityWindowContainsOwnAttack = source.activityWindowContainsOwnAttack
        }
        func history() throws -> ClanMemberHistory {
            guard try ClanArchive.normalizedTag(info.tag) == info.tag, !info.name.isEmpty,
                  membership.count <= 100_000, opt.count <= 100_000 else { throw ClanDataError.invalid("Invalid snapshot member") }
            let events = try membership.map { event -> ClanMembershipEvent in
                guard let kind = ClanMembershipKind(rawValue: event.kind), event.after.map({ $0 <= event.date }) ?? true else {
                    throw ClanDataError.invalid("Invalid snapshot membership event")
                }
                return ClanMembershipEvent(kind: kind, date: event.date, after: event.after)
            }
            return ClanMemberHistory(info: info, isCurrent: isCurrent, membership: events.sorted { $0.date < $1.date },
                opt: opt.map { ClanOptObservation(date: $0.date, value: $0.value, confirmedThrough: $0.confirmedThrough) }.sorted { $0.date < $1.date },
                lastOwnAttackAt: lastOwnAttackAt, activityCheckedAt: activityCheckedAt,
                activityWindowContainsOwnAttack: activityWindowContainsOwnAttack)
        }
    }

    init(_ dataset: ClanDataset) {
        clanTag = dataset.clanTag; clanName = dataset.clanName
        latestRosterAt = dataset.latestRosterAt; latestObservationAt = dataset.latestObservationAt
        currentWarState = dataset.currentWarState; privateWarLog = dataset.privateWarLog
        members = dataset.members.sorted { $0.id < $1.id }.map(Member.init)
        wars = dataset.wars
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
    static func decode(_ data: Data, now: Date = .now) throws -> ClanSnapshot {
        guard data.count <= maximumBytes else { throw ClanDataError.invalid("Clan snapshot exceeds 16 MB") }
        let value = try decoder().decode(ClanSnapshot.self, from: data)
        _ = try value.dataset(now: now)
        return value
    }
    func encoded() throws -> Data { try Self.encoder().encode(self) }
    func dataset(now: Date = .now) throws -> ClanDataset {
        guard format == "coc-clan-snapshot", schemaVersion == 1, modelVersion == Self.modelVersion,
              timestampUnit == "unix-ms", try ClanArchive.normalizedTag(clanTag) == clanTag,
              members.count <= 5000, wars.count <= 10000,
              Set(members.map { $0.info.tag }).count == members.count,
              Set(wars.map(\.id)).count == wars.count else { throw ClanDataError.invalid("Unsupported or invalid clan snapshot") }
        let limit = now.addingTimeInterval(300)
        func valid(_ value: Date?) -> Bool {
            value.map { $0.timeIntervalSince1970.isFinite && $0 >= Date(timeIntervalSince1970: 1_000_000_000) && $0 <= limit } ?? true
        }
        guard valid(latestRosterAt), valid(latestObservationAt), members.allSatisfy({ member in
            valid(member.lastOwnAttackAt) && valid(member.activityCheckedAt)
                && member.membership.allSatisfy { valid($0.date) && valid($0.after) }
                && member.opt.allSatisfy { intent in valid(intent.date) && valid(intent.confirmedThrough)
                    && (intent.confirmedThrough.map { $0 >= intent.date } ?? true) }
        }), wars.allSatisfy({ war in
            valid(war.observedAt) && war.startsAt < war.endsAt && war.members.count <= 50
                && Set(war.members.map { $0.info.tag }).count == war.members.count
                && (war.quota.map { (1...10).contains($0) } ?? true)
        }) else { throw ClanDataError.invalid("Invalid snapshot evidence dates or wars") }
        var result = ClanDataset(ClanArchive(clanTag: clanTag))
        result.clanName = clanName; result.latestRosterAt = latestRosterAt
        result.latestObservationAt = latestObservationAt; result.currentWarState = currentWarState
        result.privateWarLog = privateWarLog; result.members = try members.map { try $0.history() }
        result.wars = wars.sorted { $0.startsAt > $1.startsAt }
        return result
    }
}

/// Union modeled history when changing source. A later complete roster owns current membership.
extension ClanDataset {
    func preservingHistory(from local: ClanDataset) throws -> ClanDataset {
        guard clanTag == local.clanTag else { throw ClanDataError.invalid("Snapshot contains another clan") }
        let primary = (latestRosterAt ?? .distantPast) >= (local.latestRosterAt ?? .distantPast) ? self : local
        let secondary = (latestRosterAt ?? .distantPast) >= (local.latestRosterAt ?? .distantPast) ? local : self
        var result = primary
        result.latestObservationAt = [latestObservationAt, local.latestObservationAt].compactMap { $0 }.max()
        var warByID = Dictionary(primary.wars.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for candidate in secondary.wars {
            guard var prior = warByID[candidate.id] else { warByID[candidate.id] = candidate; continue }
            func rank(_ value: ClanWarRecord) -> Int { (value.isSettled ? 4 : value.complete ? 2 : 0) + (value.isEnded ? 1 : 0) }
            if rank(candidate) > rank(prior) || rank(candidate) == rank(prior) && candidate.observedAt > prior.observedAt {
                var replacement = candidate
                replacement.season = replacement.season ?? prior.season; replacement.round = replacement.round ?? prior.round
                warByID[candidate.id] = replacement
            } else {
                prior.season = prior.season ?? candidate.season; prior.round = prior.round ?? candidate.round
                warByID[candidate.id] = prior
            }
        }
        result.wars = warByID.values.sorted { $0.startsAt > $1.startsAt }
        let a = Dictionary(primary.members.map { ($0.id, $0) }, uniquingKeysWith: { value, _ in value })
        let b = Dictionary(secondary.members.map { ($0.id, $0) }, uniquingKeysWith: { value, _ in value })
        result.members = Set(a.keys).union(b.keys).sorted().map { tag in
            let first = a[tag], second = b[tag]
            var member = first ?? second!
            if primary.latestRosterAt != nil { member.isCurrent = first?.isCurrent ?? false }
            var points: [Date: Bool] = [:]
            // Last confirmation points and before-change bounds prevent turning a
            // gap into an exact join or carrying a new baseline over older evidence.
            for (history, rosterAt) in [(second, secondary.latestRosterAt), (first, primary.latestRosterAt)] {
                guard let history else { continue }
                for event in history.membership {
                    let present = [.baselinePresent, .joined, .returned].contains(event.kind)
                    if let before = event.after { points[before] = !present }
                    points[event.date] = present
                }
                if let rosterAt { points[rosterAt] = history.isCurrent }
            }
            if first == nil, let rosterAt = primary.latestRosterAt { points[rosterAt] = false }
            var events: [ClanMembershipEvent] = [], previous: Bool?, lastAt: Date?, everPresent = false
            for at in points.keys.sorted() {
                let present = points[at]!
                if previous == nil { events.append(ClanMembershipEvent(kind: present ? .baselinePresent : .baselineOutside, date: at)) }
                else if present != previous {
                    events.append(ClanMembershipEvent(kind: present ? (everPresent ? .returned : .joined) : .left, date: at, after: lastAt))
                }
                everPresent = everPresent || present; previous = present; lastAt = at
            }
            member.membership = events
            member.opt = Array(Set((first?.opt ?? []) + (second?.opt ?? []))).sorted {
                $0.date == $1.date ? $0.value.rawValue < $1.value.rawValue : $0.date < $1.date
            }
            member.lastOwnAttackAt = [first?.lastOwnAttackAt, second?.lastOwnAttackAt].compactMap { $0 }.max()
            if (second?.activityCheckedAt ?? .distantPast) > (first?.activityCheckedAt ?? .distantPast), let second {
                member.activityCheckedAt = second.activityCheckedAt
                member.activityWindowContainsOwnAttack = second.activityWindowContainsOwnAttack
            }
            return member
        }
        return result
    }
}

struct ClanPublicationManifest: Codable, Sendable {
    var format = "coc-clan-publication"
    var schemaVersion = 1
    var modelVersion = ClanSnapshot.modelVersion
    var clanTag: String
    var generatedAt: Date
    var sourceLastSuccess: Date?
    var sourceIssues: [String]
    var sourceByKind: [String: Date]
    var refreshIntervalMinutes = 30
    var snapshot: File
    struct File: Codable, Sendable {
        var path: String
        var sha256: String
        var bytes: Int
    }
    func validated(clanTag expected: String, now: Date = .now) throws -> ClanPublicationManifest {
        guard format == "coc-clan-publication", schemaVersion == 1, modelVersion == ClanSnapshot.modelVersion,
              clanTag == expected, generatedAt <= now.addingTimeInterval(300),
              generatedAt > Date(timeIntervalSince1970: 1_000_000_000),
              snapshot.bytes > 0, snapshot.bytes <= ClanSnapshot.maximumBytes,
              snapshot.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              snapshot.path == "data/" + snapshot.sha256 + ".json",
              (5...1440).contains(refreshIntervalMinutes),
              sourceLastSuccess.map({ $0 <= generatedAt.addingTimeInterval(300) }) ?? true else {
            throw ClanDataError.invalid("Unsupported or invalid clan publication")
        }
        return self
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct ClanPublicationCache: Codable, Sendable {
    var manifest: ClanPublicationManifest
    var snapshotData: Data
    func snapshot() throws -> ClanSnapshot {
        guard snapshotData.count == manifest.snapshot.bytes,
              ClanPublicationManifest.digest(snapshotData) == manifest.snapshot.sha256 else {
            throw ClanDataError.invalid("Clan snapshot integrity check failed")
        }
        let value = try ClanSnapshot.decode(snapshotData)
        guard value.clanTag == manifest.clanTag else { throw ClanDataError.invalid("Snapshot contains another clan") }
        return value
    }
}

protocol ClanPublicationTransport: Sendable {
    func get(_ request: URLRequest) async throws -> ClanHTTPResponse
}

enum ClanPublicationLoader {
    static func load(connection: ClanConnection, transport: any ClanPublicationTransport,
                     cached: ClanPublicationCache? = nil, now: Date = .now) async throws -> ClanPublicationCache {
        let connection = try connection.validated()
        guard connection.mode == .snapshot, let base = URL(string: connection.baseURL + "/") else {
            throw ClanDataError.invalid("Use a static snapshot connection")
        }
        func request(_ path: String) throws -> URLRequest {
            guard let url = URL(string: path, relativeTo: base)?.absoluteURL, url.host == base.host, url.scheme == "https" else {
                throw ClanDataError.invalid("Invalid publication path")
            }
            var value = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
            value.setValue("application/json", forHTTPHeaderField: "Accept")
            return value
        }
        let response = try await transport.get(request("manifest.json"))
        guard response.status == 200, response.data.count <= 128 * 1024 else {
            throw ClanDataError.invalid("Publication manifest unavailable (HTTP \(response.status))")
        }
        let manifest = try ClanSnapshot.decoder().decode(ClanPublicationManifest.self, from: response.data)
            .validated(clanTag: connection.clanTag, now: now)
        if let cached, cached.manifest.clanTag == manifest.clanTag, cached.manifest.generatedAt > manifest.generatedAt {
            _ = try cached.snapshot()
            return cached
        }
        if let cached, cached.manifest.clanTag == manifest.clanTag,
           cached.manifest.snapshot.sha256 == manifest.snapshot.sha256,
           cached.manifest.snapshot.bytes == manifest.snapshot.bytes {
            _ = try cached.snapshot()
            return ClanPublicationCache(manifest: manifest, snapshotData: cached.snapshotData)
        }
        let data = try await transport.get(request(manifest.snapshot.path))
        guard data.status == 200, data.data.count <= ClanSnapshot.maximumBytes else {
            throw ClanDataError.invalid("Clan snapshot unavailable (HTTP \(data.status))")
        }
        let result = ClanPublicationCache(manifest: manifest, snapshotData: data.data)
        _ = try result.snapshot()
        return result
    }
}
