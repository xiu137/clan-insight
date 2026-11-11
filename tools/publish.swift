import Foundation

/// Compile with shared/*.swift. Only explicit publication files are written to OUTPUT.
@main struct PublishClanSnapshot {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 4, args.count.isMultiple(of: 2) else {
            throw ClanDataError.invalid("Usage: publish --input ARCHIVE --output DIRECTORY [--seed ARCHIVE] [--status JSON] [--previous DIRECTORY]")
        }
        var options: [String: String] = [:]
        for i in stride(from: 0, to: args.count, by: 2) {
            guard ["--input", "--output", "--seed", "--status", "--previous", "--checks"].contains(args[i]), options[args[i]] == nil else {
                throw ClanDataError.invalid("Invalid publication option")
            }
            options[args[i]] = args[i + 1]
        }
        guard let input = options["--input"], let output = options["--output"] else {
            throw ClanDataError.invalid("Input and output are required")
        }
        let now = Date()
        var archive = try ClanArchive.decode(Data(contentsOf: URL(fileURLWithPath: input)))
        if let seed = options["--seed"] {
            var initial = try ClanArchive.decode(Data(contentsOf: URL(fileURLWithPath: seed)))
            guard initial.clanTag == archive.clanTag else { throw ClanDataError.invalid("Seed contains another clan") }
            try initial.merge(archive.observations); archive = initial
        }
        let dataset = ClanDataset(archive)
        guard dataset.latestRosterAt != nil else { throw ClanDataError.invalid("A complete roster is required for publication") }
        let snapshot = ClanSnapshot(dataset)
        let payload = try snapshot.encoded()
        _ = try ClanSnapshot.decode(payload, now: now)
        guard payload.count <= ClanSnapshot.maximumBytes else { throw ClanDataError.invalid("Snapshot exceeds its publication bound") }
        let hash = ClanPublicationManifest.digest(payload)
        var byKind: [String: Date] = [:]
        for row in archive.observations { byKind[row.kind.rawValue] = max(byKind[row.kind.rawValue] ?? .distantPast, row.confirmedAt) }
        var sourceLastSuccess = dataset.latestObservationAt
        var sourceIssues: [String] = []
        if let path = options["--status"] {
            let status = try JSONDecoder().decode(ClanJSON.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            sourceLastSuccess = status["lastSuccess"].date ?? sourceLastSuccess
            sourceIssues = status["issues"].array?.compactMap(\.string) ?? []
            if let source = status["byKind"].object {
                // Source freshness describes current server reads, not an old seed.
                byKind = source.compactMapValues(\.date)
            }
        }
        let manifest = ClanPublicationManifest(clanTag: archive.clanTag, generatedAt: now,
            sourceLastSuccess: sourceLastSuccess, sourceIssues: sourceIssues, sourceByKind: byKind,
            snapshot: .init(path: "data/" + hash + ".json", sha256: hash, bytes: payload.count))
        _ = try manifest.validated(clanTag: archive.clanTag, now: now)
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        let dataDirectory = directory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        // Retain one previous immutable payload. A cached old manifest still resolves
        // during normal deployment/cache propagation; clients retry a fresh manifest.
        if let previous = options["--previous"] {
            let root = URL(fileURLWithPath: previous, isDirectory: true)
            if let bytes = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
               let old = try? ClanSnapshot.decoder().decode(ClanPublicationManifest.self, from: bytes),
               (try? old.validated(clanTag: archive.clanTag, now: now)) != nil,
               let oldData = try? Data(contentsOf: root.appendingPathComponent(old.snapshot.path)),
               oldData.count == old.snapshot.bytes, ClanPublicationManifest.digest(oldData) == old.snapshot.sha256 {
                try oldData.write(to: directory.appendingPathComponent(old.snapshot.path), options: .atomic)
            }
        }
        try payload.write(to: directory.appendingPathComponent(manifest.snapshot.path), options: .atomic)
        try ClanSnapshot.encoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        if let path = options["--checks"] {
            struct Row: Encodable {
                var id: String; var selectedWars: Int; var attacks: Int; var expected: Int; var missed: Int
                var streak: Int; var incompleteWars: Int; var lastWarID: String?
                var sinceJoinText: String?; var sinceJoinLower: Int?; var sinceJoinUpper: Int?; var sinceJoinKnown: Bool?
                var breach: Double; var rest: Double; var activityGap: Double?; var unattributedMisses: Int; var total: Double
            }
            struct Check: Encodable {
                var reference: ClanReference; var finished: Int; var live: Int; var incomplete: Int
                var warIDs: [String]; var rows: [Row]
            }
            let checks = [ClanReference(), ClanReference(regularWars: 100, cwlSeasons: 12), ClanReference(regularWars: 0, cwlSeasons: 0)].map { reference in
                let stats = ClanStatistics(dataset: dataset, reference: reference)
                return Check(reference: reference, finished: stats.finishedWarCount, live: stats.ongoingWarCount,
                    incomplete: stats.incompleteWarCount, warIDs: stats.wars.map(\.id), rows: stats.members.map { row in
                        let cost = ClanPenaltyPolicy().evaluate(member: row.member, wars: stats.wars)
                        return Row(id: row.id, selectedWars: row.selectedWars, attacks: row.attacks, expected: row.expectedAttacks,
                            missed: row.missedAttacks, streak: row.fullUseStreak, incompleteWars: row.incompleteWars,
                            lastWarID: row.lastWarAttack?.id, sinceJoinText: row.sinceJoin?.text,
                            sinceJoinLower: row.sinceJoin?.lower, sinceJoinUpper: row.sinceJoin?.upper, sinceJoinKnown: row.sinceJoin?.knownEntry,
                            breach: cost.breach, rest: cost.rest, activityGap: cost.activityGap,
                            unattributedMisses: cost.unattributedMisses, total: cost.knownTotal)
                    })
            }
            try ClanSnapshot.encoder().encode(checks).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("Published \(dataset.members.filter(\.isCurrent).count) current members, \(dataset.wars.count) wars; snapshot \(payload.count) bytes")
    }
}
