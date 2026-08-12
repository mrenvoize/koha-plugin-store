# Legacy Plugin Discovery/Install Migration — Design

**Status:** Approved for planning
**Relates to:** `koha-plugin-store-spec.md` §4.1 (config-file-driven trust, not DB-backed), §6
(levels model), §8 (Koha-side client, `PluginStoreMinimumLevel`, no client-side-only enforcement).
Also concerns Koha core infrastructure that **predates the plugin-store project entirely** and
isn't described in any existing spec section: `plugins/plugins-home.pl`'s live GitHub/GitLab
search, and `plugins/plugins-upload.pl`'s org-allowlist install gate.

## Summary

Koha core already ships a working, admin-configurable plugin discovery-and-install feature —
`plugin_repos` + `plugins_restricted` in `koha-conf.xml` — built years before the plugin-store
project existed. Bug 35837's in-progress Koha-side plugin-store client
(`core/worktrees/bug_35837`) adds a **fourth, parallel install path**
(`Koha::REST::V1::Plugins::add()`) that doesn't know the legacy feature exists, and — this is the
important part — doesn't enforce the security control (`plugins_restricted`) that the legacy path
enforces by default. An instance running Koha's own shipped defaults is, right now, *less*
restricted installing via the plugin-store than via the path it sits beside.

This design defines the target end state: the plugin-store becomes the sole discovery backend,
one shared install routine replaces the two independently-secured ones, and — per explicit
product decision — the org-allowlist concept survives, layered as an independent AND-gate
alongside the store's own certification levels, with its enforcement mechanism fixed rather than
carried forward (the current substring match is trivially bypassable and is not preserved as-is).

## Current state (baseline — predates this project, unaffected by bug 35837 as it stands today)

Investigated directly against Koha `main` (i.e. without bug 35837's changes) to establish ground
truth before designing against it:

- **`enable_plugins`** (`koha-conf.xml`) — master on/off switch. Off by default;
  `plugins/plugins-home.pl` serves `plugins-disabled.tt` when off.
- **`pluginsdir`** — filesystem install directory (repeatable for multiple directories).
- **`plugin_repos`** (`koha-conf.xml`) — a list of `<repo>` entries, each `{name, org_name,
  service}` where `service` is `github` or `gitlab`. **Ships by default with three trusted
  orgs: ByWater Solutions, Theke Solutions, and Open Fifth** — i.e. Open Fifth's own published
  plugins already get preferential discovery in stock Koha, independent of anything this project
  does.
- **The search feature** (`plugins/plugins-home.pl`, `$plugin_search` block) — on submit, calls
  GitHub's Search API (`/search/repositories?q=...+user:$org_name+in:name,description`) or
  GitLab's API, **live, at request time**, restricted to repos named `koha-plugin-*` within the
  configured org/group, then fetches each match's latest release looking for a `.kpz` asset.
  Results (`search_results`/`search_errors`) render inline with an "Install" action posting
  `uploadfile`/`uploadlocation` to `plugins-upload.pl`.
- **`plugins_restricted`** (`koha-conf.xml`, **ships `1` by default**) — when true: hides the raw
  file-upload button entirely (`plugins-upload.tt`'s form only appears for URL-based install);
  gates URL-based install with:
  ```perl
  $do_get = any { index( $uploadlocation, $_->{org_name} ) != -1 } @{ $repos->{repo} };
  ```
  a **substring match against the download URL**. This is not a real security boundary —
  `https://evil.example.com/bywatersolutions-x/plugin.kpz` passes it. There is no checksum, no
  digest, no signature verification anywhere in `Koha::Plugins`/`Koha::Plugins::Base` — the only
  thing standing between "arbitrary internet zip" and "installed and loaded Perl code running
  inside Koha" is this string check plus whatever permission gate got the admin to this screen.
- **Permission model** — `plugins => '*'` to view (`plugins-home.pl`), `plugins => 'manage'` to
  upload/install (`plugins-upload.pl`). A real, independent ACL layer, orthogonal to everything
  above.
- **The hook/method architecture** (`Koha::Plugins.pm`, `Koha::Plugins::Base.pm`) — plugins are
  duck-typed Perl classes. `Koha::Plugins->InstallPlugins` loads each installed class and probes
  `can($method)` against a known set of hook names (`configure`, `install`, `upgrade`,
  `uninstall`, `tool`, `report`, `to_marc`, `get_valuebuilder`, `opac_online_payment`,
  `intranet_catalog_biblio_enhancements`, `ill_availability_services`, `ill_backend`), caching the
  result in a `plugin_methods` table (`Koha::Plugins::Methods`). `get_metadata` just returns the
  plugin class's own `our $metadata = {...}` hash — the same convention
  `KohaPluginStore::Task::ProcessPluginVersion`'s regex-extraction already targets, so this part
  is already aligned and **is explicitly not in scope for this migration** — see "Non-goals".

## The gap: how bug 35837 sits alongside this today

- A librarian on an instance with bug 35837 deployed has **three independent, mutually-unaware**
  ways to end up installing a plugin: manual upload, the legacy org-allowlist search, and the
  plugin-store Vue list. None of the three know the others exist.
- `Koha::REST::V1::Plugins::add()` — what the plugin-store's "Install" button POSTs to — fetches
  `kpz_url` and extracts/installs it, full stop. It does not read `plugins_restricted` or
  `plugin_repos` at all.
- Net effect: on a default-configured instance (`plugins_restricted => 1`), the plugin-store path
  is **less** restricted than the legacy path sitting next to it in the same UI. This is treated
  as a bug introduced by bug 35837's current state, not a design tradeoff to preserve — see
  "Migration/rollout ordering" for the immediate stopgap.

## Decision: keep a thin, instance-local allowlist — re-scope what it gates and how

**Resolved**, per discussion:

- **The allowlist concept survives.** It gives an individual library's IT department something
  the store's own global certification levels structurally cannot: "install anything, but only
  from vendors *we* already trust," independent of what the wider community has vetted. This
  matches the project's established philosophy (§4.1: config file + restart, not a DB-backed
  hot-reload, for something an admin changes rarely) and costs little to carry forward.
- **What does *not* survive: the enforcement mechanism.** The substring-match-against-a-URL check
  never provided real security. Carrying it into the plugin-store path (e.g. checking
  `kpz_url` the same way) would just relocate the same bypassable check, not fix it.
- **The allowlist becomes a real check against the plugin's origin repository, not its download
  URL.** The plugin-store already records the origin per plugin (`plugins.repo_url`). The check
  moves to: parse `repo_url`'s host and path, compare the owner/org segment against the
  configured list — not a substring test, and never against `kpz_url` (which could legitimately
  point at a CDN mirror, unrelated to who owns the repo). This check runs **server-side, in
  Koha's own Perl, at install time** — never client-side-only, consistent with spec §8's existing
  principle for `PluginStoreMinimumLevel`.
- **The allowlist and the store's certification level are independent, both-must-pass gates, not
  alternatives.** `PluginStoreMinimumLevel` answers "did the store vouch for this code";
  the (re-scoped) org-allowlist answers "does *this library* choose to trust who published it."
  A plugin from an untrusted vendor is blocked even if fully certified; a plugin below the
  minimum level is blocked even from an explicitly trusted vendor. Requiring **both** as
  independent AND-gates, rather than treating either as sufficient alone, is the actual fix this
  design makes to the current security gap — not just "restore the old check."

**Still open** — flag for maintainer/community input, doesn't block implementation:

- Whether `plugin_repos` should be renamed/reshaped as part of this migration. Its current
  `{name, org_name, service}` shape is GitHub/GitLab-service-specific and predates the store. A
  natural longer-term home is a flat list of trusted identifiers matched against the store's own
  `plugin_versions.author_username` (denormalized per-release author, spec §5) or `repo_url`'s
  owner segment — but reshaping a shipped, documented config block is a bigger compatibility
  question than this design needs to force. Recommendation: leave the config block's shape alone
  for this migration, just change what it's checked against internally.

## Target architecture (end state)

**Discovery** — `plugins-home.pl`'s live GitHub/GitLab Search-API call is removed entirely,
replaced by a call to the plugin-store's public discovery API (today: `GET
/api/plugins?koha_version_release=...`, the same endpoint bug 35837's Vue client already calls;
`/api/v1/discover` once that lands per spec §11 step 7). One discovery mechanism, not two. The
search-box UX is preserved — free-text filtering feels the same to a librarian — but as
client-side filtering of an already-fetched list, not a fresh outbound API call per search.

**Install** — `plugins-upload.pl` (manual upload) and `Koha::REST::V1::Plugins::add()`
(store-driven) converge on one shared Perl routine (exact module/method naming TBD at
implementation time) that always runs, regardless of entry path:

1. Extension/zip-validity check (existing behaviour, kept).
2. Compute the downloaded `.kpz`'s SHA-256 digest.
3. If the store has published a signed manifest for this exact version (spec §4.3 / build-order
   step 6 — **not built yet, anywhere**), verify the Ed25519 signature against Koha's baked-in
   public key; reject on mismatch. Until store-side signing exists, this step is an explicit
   no-op that always passes — tracked as a known gap (see "Migration/rollout ordering"), not
   silently skipped forever.
4. Check `PluginStoreMinimumLevel` (new syspref) against the store's reported
   `certification_tier` for this version — only applicable when the version has a known
   plugin-store provenance at all. A manual upload with no corresponding store record has no
   tier to check, and is gated purely by step 5 (same as today's behaviour when `plugins_restricted`
   is off).
5. Check the re-scoped org-allowlist against `repo_url`'s parsed host/org, if `plugins_restricted`
   is on. A manual upload with no known `repo_url` (a bare local zip) is, by definition, ungated
   by this step — same as today.
6. Only once all applicable checks pass: extract to `pluginsdir`, call the existing
   `Koha::Plugins->InstallPlugins` — **entirely unchanged**.

**Config** —
- `plugin_repos`: kept, shape unchanged, semantics re-scoped (checked against `repo_url`, never
  `uploadlocation`/`kpz_url`).
- `plugins_restricted`: kept as the on/off toggle for whether the allowlist is enforced at all —
  same meaning as today, different (real) enforcement mechanism underneath.
- New: `PluginStoreMinimumLevel` syspref. Values should match the store's actual certification
  tiers — currently `INCOMPLETE`/`STRUCTURAL`/`CERTIFIED` (`KohaPluginStore::Task::ProcessPluginVersion`)
  — rather than spec §6's original four-rank naming, since tiers are the only trust signal the
  store actually computes today. Revisit if/when author-reputation levels (spec §6 ranks 3–4,
  explicitly deferred by the check-pipeline design) get built.
- `plugin_store_url` — already added this session (`etc/koha-conf.xml`, `bug_35837`), no further
  change needed here.

## Non-goals / explicitly out of scope

- **Store-side Ed25519 signing** (spec §4.3, build-order step 6). This design assumes it doesn't
  exist yet and defines the install routine's signature-check step as a no-op until it does — see
  "Migration/rollout ordering" for how that gets swapped in later without another migration.
- **`Koha::Plugins::Base`/`Koha::Plugins.pm`'s hook-method architecture** (`tool`/`report`/
  `configure`/etc., the `plugin_methods` cache table). Entirely orthogonal to plugin provenance —
  must keep working completely unmodified.
- **GitLab support in the plugin-store's own discovery API.** The legacy feature supports GitLab
  org search today; the store currently only ingests GitHub repos. Not a blocker for this
  migration (falls out naturally once/if the store adds GitLab support), but explicitly flagged
  as a capability this migration would otherwise silently drop for any instance whose
  `plugin_repos` currently lists a `service: gitlab` entry.
- **Removing manual upload.** Kept as an unsupported/advanced escape hatch, ungated by
  store-specific checks — identical to today's behaviour when `plugins_restricted` is off.

## Migration/rollout ordering

1. **Immediate stopgap, independent of everything else below:** make
   `Koha::REST::V1::Plugins::add()` honour `plugins_restricted`/`plugin_repos` using the
   *existing* (weak) substring check, so bug 35837 doesn't ship an active security regression
   relative to the path it sits beside in the UI. This is deliberately not the final fix — it's
   closing the gap with the smallest possible change while the real fix (below) is built.
2. Build the shared install routine (digest computation; org-allowlist re-scoped to `repo_url`;
   no-op signature step) and re-point both `plugins-upload.pl` and
   `Koha::REST::V1::Plugins::add()` at it. This step supersedes step 1's stopgap check.
3. Add the `PluginStoreMinimumLevel` syspref and wire the level check into the shared install
   routine.
4. Retire the live GitHub/GitLab search in `plugins-home.pl`; replace with a plugin-store
   discovery API call.
5. **Tracked separately, not part of this migration's implementation plan:** once store-side
   signing lands (spec step 6), swap the install routine's no-op signature step for a real
   verification. No further migration needed at that point — the seam already exists.

## Testing

- The shared install routine gets its own unit tests independent of either HTTP entry point:
  digest computation, allowlist matching (including the specific bypass case — a URL/repo
  containing an org name as a substring of an unrelated host — must now correctly *fail*, closing
  the regression test gap the current substring check has no coverage for today), minimum-level
  gating, and the no-op signature step's explicit pass-through behaviour.
- `plugins-upload.pl` and `Koha::REST::V1::Plugins::add()` each get an integration test asserting
  they call the shared routine and correctly surface its rejection reasons (distinct error
  messages/response codes per failed gate, not one generic "install failed").
- A fixture repo/version combination specifically constructed to pass the old substring check but
  fail the new host/org-parsed check, to prevent this exact class of bug recurring.
