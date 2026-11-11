import Foundation

struct ClanReference: Codable, Hashable, Sendable {
    var regularWars = 10
    var cwlSeasons = 1

    func wars(in dataset: ClanDataset) -> [ClanWarRecord] {
        let normal = dataset.wars.filter { !$0.isCWL }
        let ended = normal.filter(\.isEnded).prefix(max(0, regularWars))
        let live = regularWars > 0 ? normal.filter { !$0.isEnded }.prefix(1) : [].prefix(1)
        let league = dataset.wars.filter(\.isCWL)
        let keys = league.map { $0.seasonKey }
        var distinct: [String] = []
        for key in keys where !distinct.contains(key) { distinct.append(key) }
        let included = Set(distinct.prefix(max(0, cwlSeasons)))
        return (Array(ended) + Array(live) + league.filter { included.contains($0.seasonKey) }).sorted { $0.startsAt > $1.startsAt }
    }
}

extension ClanWarRecord {
    var seasonKey: String {
        if let season { return season }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month], from: startsAt)
        return String(format: "unmapped:%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
    func member(_ tag: String) -> ClanWarMember? { members.first { $0.info.tag == tag } }
}

struct ClanCountRange: Hashable, Sendable {
    var lower: Int
    var upper: Int
    var knownEntry: Bool
    var text: String {
        if lower == upper { return String(lower) }
        if knownEntry { return "\(lower)–\(upper)" }
        return lower > 0 ? "≥\(lower)" : "—"
    }
    var sortableValue: Int? { lower == upper || lower > 0 || knownEntry ? lower : nil }
}

enum ClanPresence: Hashable, Sendable { case present, outside, unknown }

extension ClanMemberHistory {
    var latestOptIn: ClanOptIn { opt.last?.value ?? .unknown }

    /// War-level evidence: a red observation overrides green within this war.
    /// Include preparation when the API supplies its start; never carry today's
    /// flag backwards into a completed war without an overlapping observation.
    func optIn(during war: ClanWarRecord) -> ClanOptIn {
        let start = war.preparationStartsAt ?? war.startsAt
        let during = opt.filter {
            $0.date <= war.endsAt && ($0.confirmedThrough ?? $0.date) >= start
        }
        if during.contains(where: { $0.value == .out }) { return .out }
        if during.contains(where: { $0.value == .in }) { return .in }
        return .unknown
    }

    /// A recent observation on either side of the start must not straddle a change.
    /// The label is observed intent, not a claim about the exact moment the user tapped.
    func optIn(at date: Date, validity: TimeInterval = 1800) -> ClanOptIn {
        guard let before = opt.last(where: { $0.date <= date }), date.timeIntervalSince(before.confirmedThrough ?? before.date) <= validity else { return .unknown }
        if let after = opt.first(where: { $0.date > date }), after.value != before.value,
           date > (before.confirmedThrough ?? before.date) || after.date <= (before.confirmedThrough ?? before.date) { return .unknown }
        return before.value
    }

    func presence(at date: Date) -> ClanPresence {
        guard let before = membership.last(where: { $0.date <= date }) else { return .unknown }
        if let next = membership.first(where: { $0.date > date }), let after = next.after, after < date { return .unknown }
        switch before.kind {
        case .baselinePresent, .joined, .returned: return .present
        case .baselineOutside, .left: return .outside
        }
    }

    func sinceJoin(in wars: [ClanWarRecord]) -> ClanCountRange? {
        guard let entry = membership.last(where: { [.baselinePresent, .joined, .returned].contains($0.kind) }) else { return nil }
        let exit = membership.first { $0.date > entry.date && $0.kind == .left }
        let finished = wars.filter(\.isSettled)
        let lower = finished.filter { war in
            war.startsAt >= entry.date && (exit?.after.map { war.startsAt <= $0 } ?? true)
        }.count
        let upper = finished.filter { war in
            (entry.kind == .baselinePresent || entry.after.map { war.startsAt > $0 } ?? true)
            && (exit.map { war.startsAt < $0.date } ?? true)
        }.count
        return ClanCountRange(lower: lower, upper: max(lower, upper), knownEntry: entry.kind != .baselinePresent)
    }
}

struct ClanMemberStatistics: Identifiable, Sendable {
    var member: ClanMemberHistory
    var sinceJoin: ClanCountRange?
    var selectedWars: Int
    var attacks: Int
    var expectedAttacks: Int
    var missedAttacks: Int
    var fullUseStreak: Int
    var incompleteWars: Int
    var lastWarAttack: ClanWarRecord?
    var id: String { member.id }

    init(member: ClanMemberHistory, dataset: ClanDataset, wars: [ClanWarRecord]) {
        self.member = member
        sinceJoin = member.sinceJoin(in: wars)
        let appearances = wars.filter { $0.member(member.id) != nil }
        let settled = appearances.filter(\.isSettled)
        selectedWars = settled.count
        attacks = settled.reduce(0) { $0 + ($1.member(member.id)?.attacks.count ?? 0) }
        expectedAttacks = settled.reduce(0) { $0 + ($1.quota ?? 0) }
        missedAttacks = max(0, expectedAttacks - attacks)
        incompleteWars = appearances.filter { $0.isEnded && !$0.isSettled }.count
        fullUseStreak = 0
        for war in appearances.filter(\.isEnded).sorted(by: { $0.startsAt > $1.startsAt }) {
            guard war.isSettled, war.member(member.id)?.attacks.count == war.quota else { break }
            fullUseStreak += 1
        }
        lastWarAttack = dataset.wars.first { ($0.member(member.id)?.attacks.count ?? 0) > 0 }
    }
}

enum ClanMemberSort: String, CaseIterable, Codable, Sendable {
    case name, sinceJoin, attacks, lastWar, lastActivity
}

struct ClanStatistics: Sendable {
    var wars: [ClanWarRecord]
    var members: [ClanMemberStatistics]
    var finishedWarCount: Int { wars.filter(\.isSettled).count }
    var ongoingWarCount: Int { wars.filter { !$0.isEnded }.count }
    var incompleteWarCount: Int { wars.filter { $0.isEnded && !$0.isSettled }.count }

    init(dataset: ClanDataset, reference: ClanReference) {
        let selected = reference.wars(in: dataset)
        wars = selected
        members = dataset.members.map { ClanMemberStatistics(member: $0, dataset: dataset, wars: selected) }
    }

    /// nil combines current and former members before sorting, without rewriting history.
    func sorted(current: Bool?, by sort: ClanMemberSort, descending: Bool) -> [ClanMemberStatistics] {
        members.filter { member in current.map { member.member.isCurrent == $0 } ?? true }.sorted { a, b in
            let aValue: Double?, bValue: Double?
            switch sort {
            case .name:
                let order = a.member.info.name.localizedStandardCompare(b.member.info.name)
                if order == .orderedSame { return a.id < b.id }
                return descending ? order == .orderedDescending : order == .orderedAscending
            case .sinceJoin:
                aValue = a.sinceJoin?.sortableValue.map(Double.init); bValue = b.sinceJoin?.sortableValue.map(Double.init)
            case .attacks:
                aValue = a.expectedAttacks > 0 ? Double(a.attacks) : nil; bValue = b.expectedAttacks > 0 ? Double(b.attacks) : nil
            case .lastWar:
                aValue = a.lastWarAttack?.startsAt.timeIntervalSince1970; bValue = b.lastWarAttack?.startsAt.timeIntervalSince1970
            case .lastActivity:
                aValue = a.member.lastOwnAttackAt?.timeIntervalSince1970; bValue = b.member.lastOwnAttackAt?.timeIntervalSince1970
            }
            if aValue == bValue { return a.id < b.id }
            guard let aValue else { return false }; guard let bValue else { return true }
            return descending ? aValue > bValue : aValue < bValue
        }
    }

    /// Approximately fifteen rows, balanced: 47 → 16/16/15, 50 → 17/17/16.
    static func pageRanges(count: Int) -> [Range<Int>] {
        guard count > 0 else { return [0..<0] }
        let pages = max(1, Int((Double(count) / 15).rounded()))
        let base = count / pages, remainder = count % pages
        var offset = 0
        return (0..<pages).map { index in
            let size = base + (index < remainder ? 1 : 0)
            defer { offset += size }
            return offset..<(offset + size)
        }
    }
}

/// Explanatory reference costs, never a dispatch algorithm or a judgement of game skill.
/// Changes are versioned so archived evidence can be re-evaluated without rewriting facts.
struct ClanPenaltyPolicy: Codable, Hashable, Sendable {
    var version = 2
    var activityGraceDays = 7
    var activityPointsPerDay = 1.0
    var restPointsPerWarOrSeason = 1.0
    var breachPointsPerUnusedAttack = 20.0
    var elderActivityMultiplier = 0.2
    var optValiditySeconds = 1800.0 // Retained for v1 settings decoding; v2 uses the war window.

    func validate() throws {
        guard (0...365).contains(activityGraceDays), [activityPointsPerDay, restPointsPerWarOrSeason,
              breachPointsPerUnusedAttack, optValiditySeconds].allSatisfy({ $0.isFinite && $0 >= 0 }),
              elderActivityMultiplier.isFinite, (0...1).contains(elderActivityMultiplier), optValiditySeconds <= 86400 else {
            throw ClanDataError.invalid("Invalid analysis policy")
        }
    }

    func evaluate(member: ClanMemberHistory, wars: [ClanWarRecord]) -> ClanPenaltyBreakdown {
        var result = ClanPenaltyBreakdown(roleExempt: member.info.role.isExempt, elderActivityReduction: member.info.role == .admin)
        // Observe at the last successful activity read. Time spent offline by the app
        // must not silently become evidence that a player stopped playing.
        if member.activityWindowContainsOwnAttack, let last = member.lastOwnAttackAt, let read = member.activityCheckedAt {
            let days = max(0, Int(read.timeIntervalSince(last) / 86400) - activityGraceDays)
            let multiplier = member.info.role == .admin ? elderActivityMultiplier : 1
            result.activityGap = Double(days) * activityPointsPerDay * multiplier
        }
        let finished = wars.filter(\.isSettled)
        for war in finished {
            let intent = member.optIn(during: war)
            if let entry = war.member(member.id) {
                let unused = max(0, (war.quota ?? 0) - entry.attacks.count)
                if unused > 0 {
                    if intent == .in { result.breach += Double(unused) * breachPointsPerUnusedAttack }
                    else if intent == .unknown { result.unattributedMisses += unused }
                }
            }
            if !war.isCWL, member.presence(at: war.startsAt) == .present, intent == .out,
               (war.member(member.id)?.attacks.count ?? 0) == 0 {
                result.rest += restPointsPerWarOrSeason
            }
        }
        // Opting out of a whole CWL counts once, never once per each of its seven rounds.
        let seasons = Dictionary(grouping: finished.filter(\.isCWL), by: \.seasonKey)
        for season in seasons.values where !season.isEmpty {
            if season.allSatisfy({ member.presence(at: $0.startsAt) == .present
                && member.optIn(during: $0) == .out
                && ($0.member(member.id)?.attacks.count ?? 0) == 0 }) {
                result.rest += restPointsPerWarOrSeason
            }
        }
        if member.info.role.isExempt { result.activityGap = 0; result.rest = 0; result.breach = 0 }
        return result
    }
}

struct ClanPenaltyBreakdown: Hashable, Sendable {
    var roleExempt: Bool
    var elderActivityReduction: Bool
    var activityGap: Double?
    var rest = 0.0
    var breach = 0.0
    var unattributedMisses = 0
    var knownTotal: Double { (activityGap ?? 0) + rest + breach }
}
