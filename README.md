# Clan Insight

Responsive clan member analysis. GitHub Pages serves a shared, read-only snapshot; a scheduled GitHub Actions job reads the existing Cloudflare D1 archive and builds it with the same Swift facts and statistics used by the iOS app.

The site does not choose a war roster. It shows current/former membership, observed opt-in flags, selected wars, used attacks, membership history and reference costs. Incomplete wars and unselected substitutes do not become missed commitments.

## Deployment

Repository: `xiu137/clan-insight`. Intended Pages URL: `https://xiu137.github.io/clan-insight/`.

1. Select **Settings → Pages → Source → GitHub Actions**.
2. Set repository variables `CF_ACCOUNT_ID`, `CF_DATABASE_ID`, `CLAN_TAG`.
3. Set Actions secret `CF_D1_API_TOKEN` to a dedicated token with D1 Read for the source account.
4. Run **Publish clan snapshot**. Scheduled runs are at minutes 17 and 47 UTC each hour. GitHub schedules can be delayed or skipped.

Only the job reads Cloudflare. Browsers and iOS download `manifest.json` and a hash-named JSON payload from Pages without credentials. An update failure leaves the last successfully deployed site available. Artifacts retain for one day. The current and one previous immutable payload are included to handle normal cache/deployment overlap.

The existing collector remains responsible for capturing new game data. This repository does not trigger capture jobs or write to D1. The API token is not a developer game API key, and is never included in the public build.

## Local build and checks

Requires macOS with Swift 6+, Python 3.9+ and Node.js 20+; standard GitHub macOS runners provide the needed tools.

```sh
python3 tools/build.py --input /path/to/coc-clan-archive.json
node --test test/*.test.mjs
python3 -B -m unittest discover -s test -p 'test_*.py' -v
python3 -m http.server 8088 --bind 127.0.0.1 --directory dist
```

`tools/fetch_d1.py --output .private/source` accepts its credentials only through environment variables. It uses two fixed SELECT statements, bounds pagination, overrides stored JSON with the current `confirmed_at` column, and retries if the source changed during the read.

`tools/build.py` includes the historical seed before generating a publication. This preserves earlier CWL round mapping and former members missing from the initial D1 deployment. The seed contains clan API observations only, with no service credentials. Do not remove it without migrating its historical evidence.

The build writes private Swift/browser parity checks covering three reference ranges. Tests compare every member's counts, last war, since-join bounds, and reference costs to Swift. Only the static assets, manifest and referenced data are copied to `dist`; working files and credentials are excluded.

## Formats

- `coc-clan-publication`, schema 1: `generatedAt`, source capture times/issues, model version and payload path/bytes/SHA-256.
- `coc-clan-snapshot`, schema 1: modeled members, uncertainty-preserving history and wars. All dates use Unix **milliseconds**; `timestampUnit` declares the unit.
- Model version `clan-v1-policy-v2`: red observed during the war window overrides green; elders receive only the inactivity discount; leader/co-leader costs are exempt. Raw attack facts remain visible.

Snapshots can be imported and exported locally in the browser; importing does not alter the shared site. They can also be imported by the iOS app. Raw API archives remain a separate backup format and are input to the offline publisher.

The shared Swift files are generated from `ios/CoCPlanner/Core/Clan` in the parent personal project using `tools/ios/sync-clan-web-model.py`; do not modify just one copy. This standalone repository excludes Ninja, personal village upgrades, login sessions and the rest of the iOS project.

Unofficial fan project; not affiliated with Supercell.
