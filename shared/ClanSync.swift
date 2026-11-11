import Foundation

struct ClanConnection: Codable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable { case relay, collector, snapshot }
    var mode: Mode = .relay
    var baseURL: String
    var clanTag: String

    func validated() throws -> ClanConnection {
        guard let url = URL(string: baseURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              (mode == .snapshot || url.path.isEmpty || url.path == "/"),
              !url.path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw ClanDataError.invalid("Use an HTTPS service origin; snapshot sites may include a project path")
        }
        return ClanConnection(mode: mode, baseURL: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                              clanTag: try ClanArchive.normalizedTag(clanTag))
    }
}

struct ClanHTTPResponse: Sendable {
    var status: Int
    var data: Data
    var receivedAt: Date
    var serverDate: String?
    var cacheMaxAge: Int?
}

protocol ClanHTTPTransport: Sendable {
    func get(path: String) async throws -> ClanHTTPResponse
}

enum ClanSyncFailure: LocalizedError {
    case authentication
    var errorDescription: String? { "Clan service authentication failed; check the connection credentials" }
}

struct ClanSyncResult: Sendable {
    var observations: [ClanObservation] = []
    var issues: [String] = []
}

/// Foreground fallback. A failed member request never turns into an opt-out or a departure.
/// Four network requests at a time; no game actions, no village/player-token verification.
enum ClanAPICollector {
    private struct Batch: Sendable {
        var observations: [ClanObservation] = []
        var issues: [String] = []
    }

    static func collect(clanTag: String, transport: any ClanHTTPTransport,
                        existing: ClanArchive?, now: Date = .now) async throws -> ClanSyncResult {
        let encoded = clanTag.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let base = "/v1/clans/" + encoded
        var pending = [base, base + "/currentwar", base + "/currentwar/leaguegroup", base + "/warlog?limit=50"]
        let old = existing?.observations ?? []
        // Retain cache-age provenance. Explicit sync still respects the upstream cache window.
        func due(_ path: String) -> Bool {
            guard let route = ClanAPIKind.route(path), let prior = old.last(where: { $0.kind == route.0 && $0.subject == route.1 }) else { return true }
            let minimum = route.0 == .warlog ? 21600.0 : route.0 == .cwlwar || route.0 == .cwlgroup ? 600.0 : route.0 == .clan ? 120.0 : 60.0
            return now.timeIntervalSince(prior.confirmedAt) >= max(minimum, Double(prior.cacheMaxAge ?? 0))
        }
        let first = try await batch(pending.filter(due), transport: transport)
        guard !due(base) || first.observations.contains(where: { $0.kind == .clan }) else {
            throw ClanDataError.invalid("No complete clan roster was available; existing records were kept")
        }
        let roster = first.observations.last(where: { $0.kind == .clan }) ?? old.last(where: { $0.kind == .clan })
        guard let roster, roster.payload["tag"].string?.uppercased() == clanTag,
              let members = roster.payload["memberList"].array,
              roster.payload["members"].int == members.count,
              members.compactMap(ClanMemberInfo.init).count == members.count,
              Set(members.compactMap { $0["tag"].string }).count == members.count else {
            throw ClanDataError.invalid("No complete clan roster was available; existing records were kept")
        }
        pending = members.compactMap { $0["tag"].string }.flatMap { tag -> [String] in
            let player = "/v1/players/" + tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            return [player, player + "/battlelog"]
        }
        let group = first.observations.last(where: { $0.kind == .cwlgroup }) ?? old.last(where: { $0.kind == .cwlgroup })
        for round in group?.payload["rounds"].array ?? [] {
            let tags = Set(round["warTags"].array?.compactMap(\.string).filter { $0 != "#0" } ?? [])
            let known = old.last { $0.kind == .cwlwar && tags.contains($0.subject)
                && ClanWarRecord(observation: $0, clanTag: clanTag) != nil }
            if let known, ClanWarRecord(observation: known, clanTag: clanTag)?.isSettled == true { continue }
            // Once our war for a round is identified, never re-fetch its three unrelated wars.
            for tag in known.map({ [$0.subject] }) ?? Array(tags) {
                pending.append("/v1/clanwarleagues/wars/" + tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
            }
        }
        let second = try await batch(pending.filter(due), transport: transport)
        let observations = (first.observations + second.observations).filter { observation in
            observation.kind != .cwlwar || ClanWarRecord(observation: observation, clanTag: clanTag) != nil
        }
        return ClanSyncResult(observations: observations, issues: first.issues + second.issues)
    }

    private static func batch(_ paths: [String], transport: any ClanHTTPTransport) async throws -> Batch {
        var result = Batch()
        for start in stride(from: 0, to: paths.count, by: 4) {
            try Task.checkCancellation()
            let chunk = paths[start..<min(start + 4, paths.count)]
            let values = try await withThrowingTaskGroup(of: Batch.self) { group in
                for path in chunk {
                    group.addTask {
                        do {
                            let response = try await transport.get(path: path)
                            if response.status == 401 { throw ClanSyncFailure.authentication }
                            guard let route = ClanAPIKind.route(path) else { return Batch() }
                            // No league group outside CWL is a normal, empty result.
                            if response.status == 404 && route.0 == .cwlgroup { return Batch() }
                            guard response.status == 200 else {
                                return Batch(issues: ["\(route.0.rawValue): HTTP \(response.status)"])
                            }
                            guard response.data.count <= 8 * 1024 * 1024 else { return Batch(issues: ["\(route.0.rawValue): response too large"]) }
                            let payload = try JSONDecoder().decode(ClanJSON.self, from: response.data)
                            let observation = try ClanObservation(kind: route.0, subject: route.1,
                                observedAt: response.receivedAt, sourcePath: path, serverDate: response.serverDate,
                                cacheMaxAge: response.cacheMaxAge, payload: reduced(payload, kind: route.0))
                            return Batch(observations: [observation])
                        } catch let error as ClanSyncFailure { throw error }
                        catch is CancellationError { throw CancellationError() }
                        catch { return Batch(issues: ["\(ClanAPIKind.route(path)?.0.rawValue ?? "API"): request failed"]) }
                    }
                }
                var rows: [Batch] = []
                for try await value in group { rows.append(value) }
                return rows
            }
            for value in values { result.observations += value.observations; result.issues += value.issues }
        }
        return result
    }

    static func reduced(_ value: ClanJSON, kind: ClanAPIKind) -> ClanJSON {
        func fields(_ raw: ClanJSON, _ keys: [String]) -> ClanJSON {
            .object(Dictionary(uniqueKeysWithValues: keys.compactMap { key in raw.object?[key].map { (key, $0) } }))
        }
        switch kind {
        case .clan:
            var data = fields(value, ["tag", "name", "members", "isWarLogPublic"]).object ?? [:]
            data["memberList"] = .array((value["memberList"].array ?? []).map {
                fields($0, ["tag", "name", "role", "townHallLevel"])
            }.sorted { ($0["tag"].string ?? "") < ($1["tag"].string ?? "") })
            return .object(data)
        case .player:
            var data = fields(value, ["tag", "name", "role", "townHallLevel", "warPreference"]).object ?? [:]
            if value["clan"].object != nil { data["clan"] = fields(value["clan"], ["tag"]) }
            return .object(data)
        case .battlelog:
            let attacks = (value["items"].array ?? []).filter { $0["attack"].bool == true }
            let latest = attacks.max { ($0["battleTimestamp"].date ?? .distantPast) < ($1["battleTimestamp"].date ?? .distantPast) }
            return .object(["items": .array(latest.map { [fields($0, ["attack", "battleTimestamp", "battleType"])] } ?? [])])
        default: return value
        }
    }
}
