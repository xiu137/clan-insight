import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { statistics, pageRanges, optDuring, penalty, sortedMembers, validateSnapshot, warMemberResult } from "../public/stats.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
test("Published browser facts match Swift for all members and reference ranges", { skip: !existsSync(root + ".private/parity.json") }, () => {
  const manifest = JSON.parse(readFileSync(root + "dist/manifest.json"));
  const data = validateSnapshot(JSON.parse(readFileSync(root + "dist/" + manifest.snapshot.path)));
  const checks = JSON.parse(readFileSync(root + ".private/parity.json"));
  assert.equal(checks.length, 3);
  for (const expected of checks) {
    const stats = statistics(data, expected.reference);
    assert.deepEqual([stats.finished, stats.live, stats.incomplete], [expected.finished, expected.live, expected.incomplete]);
    assert.deepEqual(stats.wars.map(x => x.id), expected.warIDs);
    assert.equal(stats.members.length, expected.rows.length);
    for (const check of expected.rows) {
      const row = stats.members.find(x => x.member.info.tag === check.id);
      const actual = { id: row.member.info.tag, selectedWars: row.selectedWars, attacks: row.attacks, expected: row.expected,
        missed: row.missed, streak: row.streak, incompleteWars: row.incompleteWars,
        lastWarID: row.lastWar?.id, sinceJoinText: row.sinceJoin?.text, sinceJoinLower: row.sinceJoin?.lower,
        sinceJoinUpper: row.sinceJoin?.upper, sinceJoinKnown: row.sinceJoin?.knownEntry,
        breach: row.penalty.breach, rest: row.penalty.rest, activityGap: row.penalty.activityGap,
        unattributedMisses: row.penalty.unattributedMisses, total: row.penalty.total };
      // Codable omits nil fields; normalize that representation before comparing.
      assert.deepEqual(JSON.parse(JSON.stringify(actual, (_, value) => value == null ? undefined : value)), check);
    }
  }
});

test("Balanced member pagination never loses or repeats a row", () => {
  assert.deepEqual(pageRanges(45), [[0, 15], [15, 30], [30, 45]]);
  assert.deepEqual(pageRanges(47), [[0, 16], [16, 32], [32, 47]]);
  assert.deepEqual(pageRanges(0), [[0, 0]]);
});
test("Red observations override green only within the war window", () => {
  const member = { info: { tag: "#AAA", role: "member" }, membership: [], opt: [{ date: 100, value: "in" }, { date: 150, value: "out" }] };
  assert.equal(optDuring(member, { startsAt: 80, endsAt: 200 }), "out");
  assert.equal(optDuring(member, { startsAt: 160, endsAt: 200 }), "unknown");
  assert.equal(optDuring(member, { preparationStartsAt: 50, startsAt: 160, endsAt: 200 }), "out");
});
test("A green substitute is not a missed commitment", () => {
  const member = { info: { tag: "#AAA", role: "member" }, opt: [{ date: 100, value: "in" }], membership: [], activityWindowContainsOwnAttack: false };
  const war = { id: "war", startsAt: 50, endsAt: 150, state: "warEnded", complete: true, quota: 2, members: [] };
  assert.equal(penalty(member, [war]).breach, 0);
  const result = statistics({ members: [member], wars: [war] }, { regularWars: 10, cwlSeasons: 1 });
  assert.equal(result.members[0].expected, 0);
});
test("Unknown last-war dates remain last in either direction", () => {
  const rows = [null, 10, 20].map((startsAt, i) => ({ member: { info: { tag: "#AA" + i } }, lastWar: startsAt == null ? null : { startsAt } }));
  assert.equal(sortedMembers(rows, "lastWar", true).at(-1).lastWar, null);
  assert.equal(sortedMembers(rows, "lastWar", false).at(-1).lastWar, null);
});

test("Regular war shows every attack in attack order, including zero and unknown stars", () => {
  const war = { state: "warEnded", complete: true, quota: 2, members: [
    { info: { tag: "#AAA" }, mapPosition: 12, attacks: [{ order: 70, stars: 3 }, { order: 24, stars: 0 }] },
  ] };
  const result = warMemberResult("#AAA", war);
  assert.equal(result.mapPosition, 12);
  assert.deepEqual(result.attacks.map(x => x.stars), [0, 3]);
  assert.equal(result.symbol, "2/2");
  assert.equal(result.style, "hit");
  assert.equal(war.members[0].attacks[0].order, 70); // Presentation does not mutate archived facts.
  war.members[0].attacks = [{ order: 2 }];
  const partial = warMemberResult("#AAA", war);
  assert.deepEqual(partial.attacks.map(x => x.stars), [null]);
  assert.equal(partial.symbol, "1/2");
  assert.equal(partial.style, "miss");
});

test("Map positions belong to each war and older snapshots remain unknown", () => {
  const first = { state: "warEnded", complete: true, quota: 1, isCWL: true, members: [
    { info: { tag: "#BBB" }, mapPosition: 1, attacks: [] },
    { info: { tag: "#AAA" }, mapPosition: 15, attacks: [{ stars: 0 }] },
  ] };
  assert.equal(warMemberResult("#AAA", first).mapPosition, 15);
  assert.equal(warMemberResult("#AAA", first).symbol, "0★");
  const second = structuredClone(first); second.members[1].mapPosition = 12;
  assert.equal(warMemberResult("#AAA", second).mapPosition, 12);
  delete second.members[1].mapPosition;
  assert.equal(warMemberResult("#AAA", second).mapPosition, null);
  assert.equal(warMemberResult("#CCC", first).selected, false);
  assert.equal(warMemberResult("#CCC", first).symbol, "—");
  second.members[1].mapPosition = 40; // CWL API position may exceed the selected team size.
  assert.equal(warMemberResult("#AAA", second).mapPosition, 40);
});

test("No attack, not selected, and incomplete wars keep distinct states", () => {
  const war = { state: "warEnded", complete: true, quota: 2, members: [{ info: { tag: "#AAA" }, attacks: [] }] };
  assert.equal(warMemberResult("#AAA", war).symbol, "×");
  assert.equal(warMemberResult("#AAA", war).style, "miss");
  assert.equal(warMemberResult("#BBB", war).symbol, "—");
  war.complete = false;
  assert.equal(warMemberResult("#AAA", war).symbol, "…");
  assert.equal(warMemberResult("#AAA", war).style, "live");
});
