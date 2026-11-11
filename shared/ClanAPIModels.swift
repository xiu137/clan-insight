import Foundation
import CryptoKit

/// Keeps unmodelled API fields intact when an archive is exported again.
enum ClanJSON: Codable, Hashable, Sendable {
    case object([String: ClanJSON]), array([ClanJSON]), string(String), integer(Int64), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([ClanJSON].self) { self = .array(v) }
        else { self = .object(try value.decode([String: ClanJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> ClanJSON { object?[key] ?? .null }
    var object: [String: ClanJSON]? { if case .object(let v) = self { v } else { nil } }
    var array: [ClanJSON]? { if case .array(let v) = self { v } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var int: Int? {
        if case .integer(let v) = self { return Int(exactly: v) }
        if case .number(let v) = self, v.rounded() == v, v >= Double(Int.min), v < Double(Int.max) { return Int(v) }
        return nil
    }
    var date: Date? { string.flatMap(ClanDate.parse) }

    var containsCredentials: Bool {
        switch self {
        case .object(let fields): return fields.contains {
            ["authorization", "password", "cookie", "token", "api_key", "apikey", "app_token", "worker_token", "secret"].contains($0.key.lowercased())
                || $0.value.containsCredentials
        }
        case .array(let values): return values.contains(where: \.containsCredentials)
        default: return false
        }
    }
}

enum ClanDate {
    static func parse(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let compact = DateFormatter()
        compact.locale = Locale(identifier: "en_US_POSIX")
        compact.timeZone = TimeZone(secondsFromGMT: 0)
        compact.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return compact.date(from: text)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = parse(value) else { throw ClanDataError.invalid("Invalid observation date") }
            return date
        }
        return decoder
    }

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var value = encoder.singleValueContainer()
            try value.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

enum ClanDataError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { text } else { nil } }
}

enum ClanAPIKind: String, Codable, Sendable, CaseIterable {
    case clan, player, battlelog, currentwar, cwlgroup, cwlwar, warlog

    static func route(_ path: String) -> (ClanAPIKind, String)? {
        guard let routePath = path.split(separator: "?", maxSplits: 1).first else { return nil }
        let parts = routePath.split(separator: "/").map(String.init)
        guard parts.first == "v1", parts.count >= 3 else { return nil }
        let subject = (parts[2].removingPercentEncoding ?? parts[2]).uppercased()
        if parts[1] == "players" {
            if parts.count == 3 { return (.player, subject) }
            if parts.count == 4, parts[3] == "battlelog" { return (.battlelog, subject) }
        }
        if parts[1] == "clans" {
            if parts.count == 3 { return (.clan, subject) }
            if parts.count == 4, parts[3] == "currentwar" { return (.currentwar, subject) }
            if parts.count == 4, parts[3] == "warlog" { return (.warlog, subject) }
            if parts.count == 5, parts[3] == "currentwar", parts[4] == "leaguegroup" { return (.cwlgroup, subject) }
        }
        if parts.count == 3, parts[1] == "clanwarleagues" { return nil }
        if parts.count == 4, parts[1] == "clanwarleagues", parts[2] == "wars" {
            return (.cwlwar, (parts[3].removingPercentEncoding ?? parts[3]).uppercased())
        }
        return nil
    }
}

struct ClanObservation: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: ClanAPIKind
    var subject: String
    var observedAt: Date
    var confirmedAt: Date
    var sourcePath: String
    var serverDate: String?
    var cacheMaxAge: Int?
    var payload: ClanJSON

    init(kind: ClanAPIKind, subject: String, observedAt: Date, confirmedAt: Date? = nil,
         sourcePath: String, serverDate: String? = nil, cacheMaxAge: Int? = nil, payload: ClanJSON) throws {
        guard payload.object != nil, !payload.containsCredentials else { throw ClanDataError.invalid("Archive contains unsupported data or credentials") }
        guard let route = ClanAPIKind.route(sourcePath), route.0 == kind, route.1 == subject.uppercased() else {
            throw ClanDataError.invalid("Observation does not match its API route")
        }
        self.kind = kind; self.subject = subject.uppercased()
        self.observedAt = Date(timeIntervalSince1970: (observedAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        self.confirmedAt = Date(timeIntervalSince1970: (max(observedAt, confirmedAt ?? observedAt).timeIntervalSince1970 * 1000).rounded() / 1000)
        self.sourcePath = sourcePath
        self.serverDate = serverDate; self.cacheMaxAge = cacheMaxAge; self.payload = payload
        let encoded = try ClanDate.encoder().encode(payload)
        id = SHA256.hash(data: Data((kind.rawValue + ":" + self.subject + ":" + String(format: "%.3f", self.observedAt.timeIntervalSince1970) + ":").utf8) + encoded).map { String(format: "%02x", $0) }.joined()
    }
}

enum ClanRole: String, Codable, Sendable, CaseIterable {
    case member, admin, coLeader, leader, unknown
    var isExempt: Bool { self == .leader || self == .coLeader }
    var inactivityMultiplier: Double { isExempt ? 0 : self == .admin ? 0.2 : 1 }
}

enum ClanOptIn: String, Codable, Sendable { case `in`, out, unknown }

struct ClanMemberInfo: Codable, Hashable, Identifiable, Sendable {
    var tag: String
    var name: String
    var townHall: Int?
    var role: ClanRole
    var id: String { tag }

    init?(_ json: ClanJSON) {
        guard let tag = json["tag"].string, tag.uppercased().range(of: #"^#[A-Z0-9]{3,15}$"#, options: .regularExpression) != nil,
              let name = json["name"].string, !name.isEmpty else { return nil }
        self.tag = tag.uppercased(); self.name = name
        townHall = json["townHallLevel"].int ?? json["townhallLevel"].int
        role = ClanRole(rawValue: json["role"].string ?? "") ?? .unknown
    }
}

struct ClanWarAttack: Codable, Hashable, Sendable {
    var attacker: String
    var defender: String?
    var order: Int?
    var stars: Int?
}

struct ClanWarMember: Codable, Hashable, Sendable {
    var info: ClanMemberInfo
    var attacks: [ClanWarAttack]
}

struct ClanWarRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var isCWL: Bool
    var season: String?
    var round: Int?
    var state: String
    var preparationStartsAt: Date?
    var startsAt: Date
    var endsAt: Date
    var observedAt: Date
    var quota: Int?
    var opponent: String
    var members: [ClanWarMember]
    var complete: Bool
    var isEnded: Bool { state == "warEnded" }
    var isSettled: Bool { isEnded && complete && quota != nil }

    init?(observation: ClanObservation, clanTag: String, season: String? = nil, round: Int? = nil) {
        let data = observation.payload
        guard [.currentwar, .cwlwar].contains(observation.kind), data["state"].string != "notInWar",
              let starts = data["startTime"].date, let ends = data["endTime"].date, ends > starts,
              let state = data["state"].string else { return nil }
        let ownSide = ["clan", "opponent"].first { data[$0]["tag"].string?.uppercased() == clanTag.uppercased() }
        guard let ownSide else { return nil }
        let own = data[ownSide], other = data[ownSide == "clan" ? "opponent" : "clan"]
        let size = data["teamSize"].int ?? 0, raw = own["members"].array ?? []
        let parsed: [ClanWarMember] = raw.compactMap { entry in
            guard let info = ClanMemberInfo(entry) else { return nil }
            let attacks = (entry["attacks"].array ?? []).compactMap { attack -> ClanWarAttack? in
                guard let attacker = attack["attackerTag"].string else { return nil }
                let stars = attack["stars"].int
                return ClanWarAttack(attacker: attacker.uppercased(), defender: attack["defenderTag"].string,
                                     order: attack["order"].int, stars: stars.flatMap { (0...3).contains($0) ? $0 : nil })
            }
            return ClanWarMember(info: info, attacks: attacks)
        }
        isCWL = observation.kind == .cwlwar; self.season = season; self.round = round
        id = isCWL ? "cwl:" + observation.subject : "regular:\(clanTag.uppercased()):\(starts.timeIntervalSince1970):\(other["tag"].string ?? "")"
        self.state = state; startsAt = starts; endsAt = ends; observedAt = observation.confirmedAt
        preparationStartsAt = data["preparationStartTime"].date.flatMap { $0 <= starts ? $0 : nil }
        let attackQuota = isCWL ? 1 : data["attacksPerMember"].int.flatMap { (1...10).contains($0) ? $0 : nil }
        quota = attackQuota
        opponent = other["name"].string ?? "—"; members = parsed
        let total = parsed.reduce(0) { $0 + $1.attacks.count }
        let orders = parsed.flatMap(\.attacks).compactMap(\.order)
        complete = size > 0 && size <= 50 && raw.count == size && parsed.count == size
            && Set(parsed.map(\.info.tag)).count == size
            && (own["attacks"].int.map { $0 == total } ?? true)
            && Set(orders).count == orders.count
            && parsed.allSatisfy { member in
                member.attacks.allSatisfy { $0.attacker == member.info.tag }
                && (attackQuota.map { member.attacks.count <= $0 } ?? true)
                && member.attacks.count == (raw.first { $0["tag"].string?.uppercased() == member.info.tag }?["attacks"].array?.count ?? 0)
            }
    }
}
