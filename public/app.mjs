import { validateSnapshot, statistics, sortedMembers, pageRanges, latestOpt, optDuring, seasonKey, settled, warMemberResult } from "./stats.mjs";

const $ = id => document.getElementById(id);
const escape = value => String(value ?? "").replace(/[&<>"']/g, x => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[x]));
const date = value => value == null ? "Unknown" : new Date(value).toLocaleDateString(undefined, { month: "short", day: "numeric" });
const fullDate = value => value == null ? "Unknown" : new Date(value).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
const clock = value => new Date(value).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
const role = member => !member.isCurrent ? "Left clan" : ({ leader: "Leader", coLeader: "Co-leader", admin: "Elder", member: "Member" }[member.info.role] ?? "Role unknown");
// Shape carries the meaning even when display settings remove the colour difference.
function optBadge(value, decorative = false) {
  const state = ["in", "out"].includes(value) ? value : "unknown";
  const label = { in: "Opted in", out: "Opted out", unknown: "War preference unknown" }[state];
  const mark = { in: '<path d="m5.5 10 3 3 6-6"/>', out: '<path d="M6 10h8"/>', unknown: '<path d="M7.5 7.5a2.5 2.5 0 0 1 5 0c0 1.7-2.5 1.8-2.5 3.5"/><path d="M10 14h.01"/>' }[state];
  return `<span class="opt-badge ${state}" ${decorative ? 'aria-hidden="true"' : `role="img" aria-label="${label}"`} title="${label}"><svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="10" cy="10" r="8"/>${mark}</svg></span>`;
}
let data = null, manifest = null, cache = null, computed = null, page = 0, selected = null, busy = false, local = false;
let sort = "lastWar", descending = true;

async function cacheDB(operation, value) {
  try {
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open("clan-insight", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("snapshots");
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    return await new Promise((resolve, reject) => {
      const transaction = db.transaction("snapshots", operation === "put" ? "readwrite" : "readonly");
      const store = transaction.objectStore("snapshots");
      const request = operation === "put" ? store.put(value, location.pathname) : store.get(location.pathname);
      let result;
      request.onsuccess = () => { result = request.result; };
      transaction.oncomplete = () => { db.close(); resolve(result); };
      transaction.onerror = () => { db.close(); reject(transaction.error); };
    });
  } catch { return null; }
}
async function bytes(url, limit) {
  const response = await fetch(url, { cache: "no-cache", credentials: "omit", redirect: "error", signal: AbortSignal.timeout(25000) });
  if (!response.ok) throw new Error(`Shared data is unavailable (HTTP ${response.status}).`);
  const chunks = [], reader = response.body.getReader(); let length = 0;
  while (true) {
    const part = await reader.read(); if (part.done) break;
    length += part.value.byteLength;
    if (length > limit) { await reader.cancel(); throw new Error("Shared file exceeds its size limit."); }
    chunks.push(part.value);
  }
  const joined = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.length; }
  return joined;
}
const sha256 = async raw => [...new Uint8Array(await crypto.subtle.digest("SHA-256", raw))].map(x => x.toString(16).padStart(2, "0")).join("");
const parse = raw => JSON.parse(new TextDecoder().decode(raw));
function validateManifest(value) {
  if (value?.format !== "coc-clan-publication" || value.schemaVersion !== 1 || value.modelVersion !== "clan-v1-policy-v2"
    || !/^#[A-Z0-9]{3,15}$/.test(value.clanTag) || !/^[a-f0-9]{64}$/.test(value.snapshot?.sha256)
    || value.snapshot.path !== `data/${value.snapshot.sha256}.json` || !Number.isInteger(value.snapshot.bytes)
    || value.snapshot.bytes <= 0 || value.snapshot.bytes > 16 * 1024 * 1024 || !Number.isFinite(value.generatedAt)
    || !Array.isArray(value.sourceIssues)) throw new Error("Unsupported shared publication.");
  return value;
}
function notice(text) { $("notice").textContent = text; $("notice").hidden = !text; }
async function loadShared() {
  if (busy) return;
  busy = true; $("refresh").disabled = true; $("import").disabled = true; $("refresh").classList.add("busy");
  try {
    const next = validateManifest(parse(await bytes(new URL("./manifest.json", location.href), 128 * 1024)));
    if (cache?.manifest?.clanTag === next.clanTag && cache.manifest.generatedAt > next.generatedAt) throw new Error("The server returned an older publication.");
    let raw = cache?.manifest?.snapshot?.sha256 === next.snapshot.sha256 ? new Uint8Array(cache.bytes) : null;
    if (!raw || raw.byteLength !== next.snapshot.bytes || await sha256(raw) !== next.snapshot.sha256) raw = await bytes(new URL(next.snapshot.path, location.href), next.snapshot.bytes);
    if (raw.byteLength !== next.snapshot.bytes || await sha256(raw) !== next.snapshot.sha256) throw new Error("Shared snapshot did not pass its integrity check.");
    const snapshot = validateSnapshot(parse(raw));
    if (snapshot.clanTag !== next.clanTag) throw new Error("Publication contains a different clan.");
    data = snapshot; manifest = next; local = false; cache = { manifest: next, bytes: raw.buffer };
    await cacheDB("put", cache);
    notice(next.sourceIssues.length ? "The collector reported incomplete updates. Existing records are preserved." : "");
    render(); $("refresh").classList.add("success");
    setTimeout(() => $("refresh").classList.remove("success"), 450);
  } catch (error) {
    if (!data && cache) {
      try {
        const savedManifest = validateManifest(cache.manifest), raw = new Uint8Array(cache.bytes);
        if (raw.byteLength !== savedManifest.snapshot.bytes || await sha256(raw) !== savedManifest.snapshot.sha256) throw new Error("Invalid local cache");
        const savedData = validateSnapshot(parse(raw));
        if (savedData.clanTag !== savedManifest.clanTag) throw new Error("Local cache contains another clan");
        manifest = savedManifest; data = savedData;
      } catch { cache = null; }
    }
    notice(data ? `Showing the last complete snapshot. ${error.message}` : `${error.message} Try again, or import a saved snapshot.`);
    if (data) render(); else $("connection-state").textContent = "No shared data";
  } finally { busy = false; $("refresh").disabled = false; $("import").disabled = false; $("refresh").classList.remove("busy"); }
}
function reference() {
  const clamp = (id, maximum) => Math.min(maximum, Math.max(0, Math.trunc(Number($(id).value)) || 0));
  return { regularWars: clamp("regular-wars", 100), cwlSeasons: clamp("cwl-seasons", 12) };
}
function render() {
  if (!data) return;
  computed = statistics(data, reference());
  $("clan-name").textContent = data.clanName; document.title = `${data.clanName} · Clan Insight`;
  $("current-count").textContent = data.latestRosterAt == null ? "?" : data.members.filter(x => x.isCurrent).length;
  $("war-count").textContent = computed.finished; $("live-count").textContent = computed.live;
  $("history-count").textContent = data.members.filter(x => !x.isCurrent).length;
  $("export").disabled = false; $("shared").hidden = !local;
  const checked = data.latestObservationAt == null ? "Unknown" : `${date(data.latestObservationAt)}, ${clock(data.latestObservationAt)}`;
  $("data-time").textContent = `${local ? "Local file" : "Source checked"} · ${checked}${!local && manifest ? ` · Published ${new Date(manifest.generatedAt).toDateString() === new Date(data.latestObservationAt).toDateString() ? clock(manifest.generatedAt) : fullDate(manifest.generatedAt)}` : ""}`;
  const old = !local && manifest && Date.now() - manifest.generatedAt > (manifest.refreshIntervalMinutes ?? 30) * 3 * 60000;
  $("connection-state").textContent = local ? "Local snapshot" : old ? "Older snapshot" : "Shared snapshot";
  $("connection-state").classList.toggle("stale", Boolean(old));
  renderRows(); renderDetails();
}
function renderRows() {
  if (!computed) return;
  const query = $("search").value.trim().toLocaleLowerCase(), flag = $("intent-filter").value;
  const rows = sortedMembers(computed.members.filter(row => ($("include-former").checked || row.member.isCurrent)
    && (flag === "all" || latestOpt(row.member) === flag)
    && (!query || `${row.member.info.name} ${row.member.info.tag}`.toLocaleLowerCase().includes(query))), sort, descending);
  const ranges = pageRanges(rows.length); page = Math.min(page, ranges.length - 1);
  const [start, end] = ranges[page];
  $("members").innerHTML = rows.slice(start, end).map(row => {
    const member = row.member, membership = member.membership.at(-1)?.kind;
    const badge = member.isCurrent && ["joined", "returned"].includes(membership) ? `<span class="badge">${membership === "joined" ? "New" : "Returned"}</span>` : "";
    const membershipMeta = member.isCurrent ? ` · ${role(member)}` : ' <span class="badge left">Left clan</span>';
    return `<tr><td><button class="member-link" data-member="${escape(member.info.tag)}">${optBadge(latestOpt(member))}<span class="name-group"><span class="name">${escape(member.info.name)}${badge}</span><span class="meta">TH ${member.info.townHall ?? "?"}${membershipMeta}</span></span></button></td>
      <td title="Reference wars since the observed entry; not an exact join date">${row.sinceJoin?.text ?? "—"}</td>
      <td class="${!row.expected ? "attack-unknown" : row.missed ? "attack-miss" : "attack-complete"}">${row.expected ? `${row.attacks}<span class="muted"> / ${row.expected}</span>` : "—"}</td>
      <td title="Last captured war in which this member attacked">${row.lastWar ? date(row.lastWar.startsAt) : "—"}</td></tr>`;
  }).join("");
  $("empty").hidden = rows.length > 0;
  $("result-count").textContent = `${rows.length} members · ${computed.finished} completed wars in reference${computed.incomplete ? ` · ${computed.incomplete} incomplete` : ""}`;
  $("page-label").textContent = rows.length ? `${start + 1}–${end} of ${rows.length}` : "0 members";
  $("page-position").textContent = `${page + 1} / ${ranges.length}`;
  $("previous").disabled = page === 0; $("next").disabled = page >= ranges.length - 1;
  document.querySelectorAll("[data-sort]").forEach(button => { button.classList.toggle("active", button.dataset.sort === sort); button.textContent = ({ name: "Member", sinceJoin: "Since join", attacks: "Attacks", lastWar: "Last war" }[button.dataset.sort]) + (button.dataset.sort === sort ? descending ? " ↓" : " ↑" : ""); });
}
function mapPositionHTML(value) {
  return value.selected ? `<span class="map-position" title="${value.mapPosition == null ? "Own war map position unknown" : `Own war map position ${value.mapPosition}`}">#${value.mapPosition ?? "?"}</span>` : "";
}
function detailHTML(row) {
  const member = row.member, seasons = [...new Set(computed.wars.filter(x => x.isCWL).map(seasonKey))];
  const cwls = seasons.map(season => {
    const wars = computed.wars.filter(x => x.isCWL && seasonKey(x) === season).sort((a, b) => a.startsAt - b.startsAt);
    const mapped = wars.every(x => x.round != null), slots = mapped ? Array.from({ length: 7 }, (_, i) => wars.find(x => x.round === i + 1)) : wars;
    return `<div class="section-label"><h3>CWL · ${escape(season.replace("unmapped:", ""))}</h3><span>${mapped ? "Rounds 1–7" : "Round labels unavailable"}</span></div><div class="rounds">${slots.map((war, i) => {
      const value = warMemberResult(member.info.tag, war); return `<div class="round"><small>${mapped ? i + 1 : date(war.startsAt)}</small><div class="round-symbol ${value.style}" title="${value.label}${war ? ` · ${escape(war.opponent)}` : ""}">${value.symbol}</div><small class="round-position">${mapPositionHTML(value) || "—"}</small></div>`;
    }).join("")}</div>`;
  }).join("");
  const regular = computed.wars.filter(x => !x.isCWL).map(war => {
    const value = warMemberResult(member.info.tag, war);
    const scores = value.attacks.map(attack => `<span class="attack-star" title="Recorded attack${Number.isInteger(attack.order) && attack.order > 0 ? ` #${attack.order}` : ""}: ${attack.stars == null ? "stars unknown" : `${attack.stars} stars`}">${attack.stars ?? "?"}★</span>`).join("");
    return `<div class="war-row">${optBadge(optDuring(member, war))}<div class="war-target"><strong>${escape(war.opponent)}</strong><small class="war-meta">${mapPositionHTML(value)}<span>${date(war.startsAt)} · ${settled(war) ? "Complete" : war.state === "warEnded" ? "Incomplete record" : war.state === "preparation" ? "Preparation" : "Ongoing"}</span></small></div><div class="war-result ${value.style}">${scores ? `<div class="attack-stars" aria-label="Recorded attack stars">${scores}</div><small title="${value.label}">${value.symbol} attacks</small>` : `<span class="war-symbol" title="${value.label}">${value.symbol}</span>`}</div></div>`;
  }).join("");
  const timeline = [
    ...member.membership.map(x => ({ at: x.date, text: ({ baselinePresent: "Present when tracking began", baselineOutside: "Outside when tracking began", joined: "Joined", left: "Left clan", returned: "Returned" }[x.kind] ?? x.kind), style: "unknown", after: x.after })),
    ...member.opt.filter((x, i, all) => i === 0 || all[i - 1].value !== x.value).map(x => ({ at: x.date, text: x.value === "in" ? "Opted in · observed" : "Opted out · observed", style: x.value, preference: true, decorative: true })),
    ...computed.wars.map(war => ({ at: war.startsAt, text: `${war.isCWL ? "CWL" : "War"} · ${war.opponent}`, style: optDuring(member, war), preference: true })),
  ].sort((a, b) => b.at - a.at).slice(0, 35);
  const cost = row.penalty;
  return `<article class="member-detail"><div class="detail-heading">${optBadge(latestOpt(member))}<h2>${escape(member.info.name)}</h2></div><p class="detail-tag">${escape(member.info.tag)} · TH ${member.info.townHall ?? "?"} · ${role(member)}</p>
    <div class="detail-totals"><div><strong>${row.expected ? `${row.attacks}/${row.expected}` : "—"}</strong><small>Attacks used</small></div><div><strong>${row.selectedWars}</strong><small>Selected wars</small></div><div><strong>${row.lastWar ? date(row.lastWar.startsAt) : "—"}</strong><small>Last war attack</small></div></div>
    ${cwls || '<p class="small">No CWL details in this reference.</p>'}
    <div class="section-label"><h3>Regular wars</h3><span>${computed.wars.filter(x => !x.isCWL).length} in reference</span></div>${regular || '<p class="small">No captured regular wars.</p>'}
    <div class="section-label"><h3>Reference costs</h3><span>${Number(cost.total.toFixed(1))}</span></div><div class="costs">${cost.roleExempt ? "Leader / co-leader: exempt. Attack facts remain visible." : `<strong>Commitments ${cost.breach}</strong> · Rest ${cost.rest} · Activity ${cost.activityGap == null ? "unknown" : Number(cost.activityGap.toFixed(1))}${member.info.role === "admin" ? " (elder reduction)" : ""}.`}${cost.unattributedMisses ? `<br>${cost.unattributedMisses} unused attack(s) have no confirmed green flag; no breach cost inferred.` : ""}<br>Last observed own attack: ${fullDate(member.lastOwnAttackAt)}.</div>
    <div class="section-label"><h3>Observed timeline</h3><span>Flags + wars + membership</span></div>${timeline.map(x => `<div class="history-item">${x.preference ? optBadge(x.style, x.decorative) : '<span class="dot" aria-hidden="true"></span>'}<span>${escape(x.text)}</span><time title="${escape(x.after ? `Observed between ${fullDate(x.after)} and ${fullDate(x.at)}` : fullDate(x.at))}">${date(x.at)}</time></div>`).join("")}
    <p class="small" style="margin-top:14px">Dates describe observations and wars. Gaps do not prove inactivity or an exact join time.</p></article>`;
}
function renderDetails() {
  if (!computed || !selected) {
    $("desktop-detail").innerHTML = '<div class="detail-placeholder"><h2>Member details</h2><p>Choose a member to review their wars, flags and membership history.</p></div>';
    $("mobile-detail").innerHTML = "";
    return;
  }
  const row = computed.members.find(x => x.member.info.tag === selected);
  if (!row) return;
  const html = detailHTML(row); $("desktop-detail").innerHTML = html; $("mobile-detail").innerHTML = html;
}
$("opt-legend").innerHTML = [["in", "Opted in"], ["out", "Opted out"], ["unknown", "Unknown"]].map(([value, label]) => `<span class="legend-item">${optBadge(value, true)}${label}</span>`).join("");
$("members").addEventListener("click", event => {
  const button = event.target.closest("[data-member]"); if (!button) return;
  selected = button.dataset.member; renderDetails();
  if (matchMedia("(max-width: 800px)").matches) $("member-dialog").showModal();
});
$("close-detail").onclick = () => $("member-dialog").close();
$("refresh").onclick = loadShared; $("shared").onclick = loadShared;
for (const id of ["regular-wars", "cwl-seasons"]) $(id).addEventListener("change", () => { page = 0; render(); });
for (const id of ["search", "include-former", "intent-filter"]) $(id).addEventListener(id === "search" ? "input" : "change", () => { page = 0; renderRows(); });
$("sort").onchange = () => { sort = $("sort").value; descending = sort !== "name"; $("descending").checked = descending; page = 0; renderRows(); };
$("descending").onchange = () => { descending = $("descending").checked; page = 0; renderRows(); };
document.querySelectorAll("[data-sort]").forEach(button => { button.onclick = () => { const next = button.dataset.sort; descending = next === sort ? !descending : next !== "name"; sort = next; $("sort").value = sort; $("descending").checked = descending; page = 0; renderRows(); }; });
$("previous").onclick = () => { page--; renderRows(); }; $("next").onclick = () => { page++; renderRows(); };
$("import").onclick = () => $("import-file").click();
$("import-file").onchange = async event => {
  try {
    const file = event.target.files[0]; if (!file) return;
    if (file.size > 16 * 1024 * 1024) throw new Error("Snapshot exceeds 16 MB.");
    const value = validateSnapshot(JSON.parse(await file.text()));
    data = value; local = true; manifest = null; selected = null; page = 0;
    notice("This snapshot is only open in your browser. Shared data is unchanged."); render();
  } catch (error) { notice(error.message); }
  event.target.value = "";
};
$("export").onclick = () => {
  if (!data) return;
  const url = URL.createObjectURL(new Blob([JSON.stringify(data)], { type: "application/json" }));
  const link = document.createElement("a"); link.href = url; link.download = "clan-snapshot.json"; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
};
cache = await cacheDB("get");
await loadShared();
setInterval(() => { if (!document.hidden && !local) loadShared(); }, 5 * 60000);
