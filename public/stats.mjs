// Fact-based counterpart of the shared Swift model. Golden parity is checked in CI.
const day = 86400000;
export const settled = war => war.state === "warEnded" && war.complete && war.quota != null;
export const seasonKey = war => war.season ?? "unmapped:" + new Date(war.startsAt).toISOString().slice(0, 7);
export const latestOpt = member => member.opt.at(-1)?.value ?? "unknown";
export function optDuring(member, war) {
  const start = war.preparationStartsAt ?? war.startsAt;
  const overlapping = member.opt.filter(x => x.date <= war.endsAt && (x.confirmedThrough ?? x.date) >= start);
  return overlapping.some(x => x.value === "out") ? "out" : overlapping.some(x => x.value === "in") ? "in" : "unknown";
}
export function presence(member, at) {
  const before = member.membership.filter(x => x.date <= at).at(-1);
  if (!before) return "unknown";
  const next = member.membership.find(x => x.date > at);
  if (next?.after != null && next.after < at) return "unknown";
  return ["baselinePresent", "joined", "returned"].includes(before.kind) ? "present" : "outside";
}
export function selectWars(data, reference = { regularWars: 10, cwlSeasons: 1 }) {
  const normal = data.wars.filter(x => !x.isCWL);
  const selected = normal.filter(x => x.state === "warEnded").slice(0, reference.regularWars);
  if (reference.regularWars > 0) selected.push(...normal.filter(x => x.state !== "warEnded").slice(0, 1));
  const league = data.wars.filter(x => x.isCWL);
  const seasons = [...new Set(league.map(seasonKey))].slice(0, reference.cwlSeasons);
  return [...selected, ...league.filter(x => seasons.includes(seasonKey(x)))].sort((a, b) => b.startsAt - a.startsAt);
}
function sinceJoin(member, wars) {
  const entry = member.membership.filter(x => ["baselinePresent", "joined", "returned"].includes(x.kind)).at(-1);
  if (!entry) return null;
  const exit = member.membership.find(x => x.date > entry.date && x.kind === "left");
  const finished = wars.filter(settled);
  const lower = finished.filter(x => x.startsAt >= entry.date && (exit?.after == null || x.startsAt <= exit.after)).length;
  const upper = Math.max(lower, finished.filter(x => (entry.kind === "baselinePresent" || entry.after == null || x.startsAt > entry.after)
    && (!exit || x.startsAt < exit.date)).length);
  const knownEntry = entry.kind !== "baselinePresent";
  return { lower, upper, knownEntry, value: lower === upper || lower > 0 || knownEntry ? lower : null,
    text: lower === upper ? String(lower) : knownEntry ? `${lower}–${upper}` : lower > 0 ? `≥${lower}` : "—" };
}
export function penalty(member, wars) {
  const roleExempt = ["leader", "coLeader"].includes(member.info.role);
  let activityGap = null, rest = 0, breach = 0, unattributedMisses = 0;
  if (member.activityWindowContainsOwnAttack && member.lastOwnAttackAt != null && member.activityCheckedAt != null) {
    activityGap = Math.max(0, Math.floor((member.activityCheckedAt - member.lastOwnAttackAt) / day) - 7)
      * (member.info.role === "admin" ? 0.2 : 1);
  }
  const finished = wars.filter(settled);
  for (const war of finished) {
    const intent = optDuring(member, war), entry = war.members.find(x => x.info.tag === member.info.tag);
    const unused = entry ? Math.max(0, war.quota - entry.attacks.length) : 0;
    if (unused && intent === "in") breach += unused * 20;
    if (unused && intent === "unknown") unattributedMisses += unused;
    if (!war.isCWL && presence(member, war.startsAt) === "present" && intent === "out" && !(entry?.attacks.length)) rest++;
  }
  for (const season of new Set(finished.filter(x => x.isCWL).map(seasonKey))) {
    if (finished.filter(x => x.isCWL && seasonKey(x) === season).every(war => presence(member, war.startsAt) === "present"
      && optDuring(member, war) === "out" && !(war.members.find(x => x.info.tag === member.info.tag)?.attacks.length))) rest++;
  }
  if (roleExempt) { activityGap = 0; rest = 0; breach = 0; }
  return { roleExempt, activityGap, rest, breach, unattributedMisses, total: (activityGap ?? 0) + rest + breach };
}
export function statistics(data, reference) {
  const wars = selectWars(data, reference);
  const members = data.members.map(member => {
    const appearances = wars.filter(x => x.members.some(y => y.info.tag === member.info.tag));
    const final = appearances.filter(settled);
    const attacks = final.reduce((sum, x) => sum + x.members.find(y => y.info.tag === member.info.tag).attacks.length, 0);
    const expected = final.reduce((sum, x) => sum + x.quota, 0);
    let streak = 0;
    for (const war of appearances.filter(x => x.state === "warEnded").sort((a, b) => b.startsAt - a.startsAt)) {
      if (!settled(war) || war.members.find(x => x.info.tag === member.info.tag).attacks.length !== war.quota) break;
      streak++;
    }
    return { member, sinceJoin: sinceJoin(member, wars), selectedWars: final.length, attacks, expected,
      missed: Math.max(0, expected - attacks), streak,
      incompleteWars: appearances.filter(x => x.state === "warEnded" && !settled(x)).length,
      lastWar: data.wars.find(x => x.members.some(y => y.info.tag === member.info.tag && y.attacks.length)) ?? null,
      penalty: penalty(member, wars) };
  });
  return { wars, members, finished: wars.filter(settled).length, live: wars.filter(x => x.state !== "warEnded").length,
    incomplete: wars.filter(x => x.state === "warEnded" && !settled(x)).length };
}
export function sortedMembers(rows, sort = "lastWar", descending = true) {
  const value = row => sort === "sinceJoin" ? row.sinceJoin?.value : sort === "attacks" ? row.expected > 0 ? row.attacks : null
    : sort === "lastWar" ? row.lastWar?.startsAt : sort === "reference" ? row.penalty.total : row.member.lastOwnAttackAt;
  return [...rows].sort((a, b) => {
    if (sort === "name") {
      const order = a.member.info.name.localeCompare(b.member.info.name, undefined, { numeric: true });
      return order ? descending ? -order : order : a.member.info.tag.localeCompare(b.member.info.tag);
    }
    const x = value(a), y = value(b);
    if (x == null && y != null) return 1;
    if (y == null && x != null) return -1;
    if (x === y) return a.member.info.tag.localeCompare(b.member.info.tag);
    return descending ? y - x : x - y;
  });
}
export function pageRanges(count) {
  if (!count) return [[0, 0]];
  const pages = Math.max(1, Math.round(count / 15)), base = Math.floor(count / pages), remainder = count % pages;
  let offset = 0;
  return Array.from({ length: pages }, (_, i) => { const start = offset; offset += base + (i < remainder ? 1 : 0); return [start, offset]; });
}
export function validateSnapshot(data) {
  if (data?.format !== "coc-clan-snapshot" || data.schemaVersion !== 1 || data.modelVersion !== "clan-v1-policy-v2"
    || data.timestampUnit !== "unix-ms" || !/^#[A-Z0-9]{3,15}$/.test(data.clanTag)
    || !Array.isArray(data.members) || data.members.length > 5000 || !Array.isArray(data.wars) || data.wars.length > 10000
    || new Set(data.members.map(x => x.info?.tag)).size !== data.members.length) throw new Error("Unsupported clan snapshot.");
  for (const member of data.members) {
    if (!member.info?.name || !/^#[A-Z0-9]{3,15}$/.test(member.info.tag) || !Array.isArray(member.membership) || !Array.isArray(member.opt)
      || member.membership.some(x => !Number.isFinite(x.date)) || member.opt.some(x => !Number.isFinite(x.date))) throw new Error("Invalid member history.");
  }
  for (const war of data.wars) {
    if (!Number.isFinite(war.startsAt) || !Number.isFinite(war.endsAt) || war.startsAt >= war.endsAt || !Array.isArray(war.members)
      || war.members.length > 50 || war.members.some(x => !x.info?.tag || !Array.isArray(x.attacks))) throw new Error("Invalid war history.");
  }
  data.wars.sort((a, b) => b.startsAt - a.startsAt);
  return data;
}
