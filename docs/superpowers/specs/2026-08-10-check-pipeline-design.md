# Automated Check Pipeline (Levels 1–2) — Design

**Status:** Approved for planning
**Relates to:** `koha-plugin-store-spec.md` §6 ("Levels model and submission workflow"). This is
build-order step 5 — the first of the levels/trust model to be implemented. Levels 3
("Trusted author") and 4 ("Community reviewed") from the master spec are **not** built here; see
"Scope and relationship to §6" below for why they've been reframed rather than deferred as-is.

## Summary

Today, `KohaPluginStore::Task::ProcessPluginVersion` (the Minion task that processes a submitted
plugin version) does a rough, binary pass/fail: it checks a plugin class file exists, inherits
`Koha::Plugins::Base`, and has minimally-complete metadata, then sets `status` to `published` or
`changes_requested`. There's no record of *which* checks ran, no distinction between checks that
must pass to publish at all versus checks that indicate a well-maintained plugin, and no way for
a plugin's page to show *why* it holds whatever quality signal it has.

This design replaces that binary outcome with a small, per-check catalogue (`review_checks`, one
row per check per version) and a three-tier automated certification badge
(`INCOMPLETE`/`STRUCTURAL`/`CERTIFIED`) computed from it — fully automated, no human in the loop,
consistent with §6's goal that automated levels shouldn't queue behind reviewer capacity.

## Prior art: what existing Koha QA tooling gets us

Four existing tools were reviewed for reuse before designing this from scratch:

- **`Koha::QA`** (`tooling/koha-qa`) — a small, dependency-light, git/CI-agnostic Perl library
  (`Koha::QA::PerlSyntax`, `Koha::QA::PerlCritic`, plus POD/spelling/tidy/security-template
  checks), explicitly designed to be shared across Koha core QA, `qa-test-tools`, and plugin
  certification. **Taken as a direct dependency** for the `PerlCritic` check (see below) — it's
  pure static analysis via PPI, so it runs safely against untrusted plugin code with no
  sandboxing needed.
- **`qa-test-tools`** (`tooling/qa-test-tools`, the `koha-qa.pl` script) — confirmed to be the
  main consumer of `Koha::QA`, but the wrapper script itself is fundamentally "git diff against
  Koha-core HEAD~N with `Bug XXXXX:` commit conventions." Not reusable, and not depended on here.
- **`koha-plugin-certification`** (KPCA) — a self-described work-in-progress/proof-of-concept
  that validates a local plugin directory against a very similar check set (Structure, Metadata,
  Dependencies, Security, Style, CodeQuality, Tidy, Tests). Its per-check module shape
  (`->new(...)->run($plugin_dir)` returning `{pass, details}`) is the pattern this design's
  `KohaPluginStore::Check::*` classes follow. Its scoring model (a weighted average across all
  checks, thresholded into `INCOMPLETE`/`STRUCTURAL`/`TRUSTED`/`CERTIFIED`) was **not** adopted —
  see "Tier computation" below for why. Worth upstreaming our required-check set and the
  hard-gate-override concept to KPCA once this is built, since it's a real gap in their model too.
- **`core/worktrees/koha-qa`** — a working branch of Koha core itself, unrelated to plugin QA
  tooling (carries plugin-*infrastructure* commits: SAML2-as-plugin, valuebuilders-as-plugins, a
  plugin loader refactor). No action taken here.

## Scope and relationship to §6

§6 describes four ranks on one ladder: Automated → Static analysis → Trusted author → Community
reviewed. Working through the design surfaced that the top two aren't actually the same kind of
thing as the bottom two, and conflating them causes real problems (see "Levels naming" below).
This design reframes them as two independent concerns:

- **Certification tier** (this design's scope) — purely automated, computed by the check
  pipeline described here, always computed for every submitted version, gates whether it
  publishes at all.
- **Author reputation and community/user ratings** (explicitly out of scope, future work) — a
  reframing of §6's "Trusted author" and "Community reviewed" ranks. Discussion during this
  design surfaced that these aren't naturally per-version pass/fail gates the way certification
  is: user ratings are ongoing librarian feedback ("this works great") accumulated over time, not
  a one-off check result, and author reputation is more naturally a discoverability/ranking
  weight derived from an author's track record than a certification a single version earns. Both
  need their own data shape (aggregated feedback, not a `review_checks` row) and their own
  brainstorm — deliberately not designed here to avoid baking in the wrong assumption. `plugins`
  and `plugin_versions` should be treated as not-yet-final with respect to these concerns.

Because of this split, `current_level_id`/`level_history` (§6's proposed schema, designed for a
single linear ladder including human-driven rank changes) is not built. The certification tier
is fully re-derivable from `review_checks` at any time, so there's nothing to keep a ledger of.

## Data model

New Postgres migration on top of the existing schema (`worktree-submission-pipeline`'s migration
4 is the latest at time of writing):

```sql
ALTER TABLE plugin_versions ADD COLUMN certification_tier TEXT;

CREATE TABLE review_checks (
    id                SERIAL PRIMARY KEY,
    plugin_version_id INTEGER REFERENCES plugin_versions(id) ON DELETE CASCADE,
    check_name        TEXT NOT NULL,
    required          BOOLEAN NOT NULL,
    passed            BOOLEAN NOT NULL,
    message           TEXT,
    checked_at        TIMESTAMPTZ DEFAULT now(),
    UNIQUE (plugin_version_id, check_name)
);
```

- `certification_tier` sits alongside the existing `status` column, not in place of it. `status`
  remains the publish-gate lifecycle field already wired through templates and `/api/plugins`.
  `certification_tier` is the finer-grained quality badge: `INCOMPLETE` always pairs with
  `status = 'changes_requested'`; `STRUCTURAL`/`CERTIFIED` always pair with `status = 'published'`.
  A new `status` value, `check_error`, is added for check-infrastructure failures distinct from
  plugin defects (see "Error handling").
- `review_checks` has one row per check per version, upserted (via the unique constraint) rather
  than accumulated, so a check can be safely re-run without duplicate history.
- Everything here is scoped to the specific `plugin_version` (the tag/release), not the plugin as
  a whole — matching §6's own wording ("the version has already cleared level 1"). A developer
  whose version fails checks is expected to cut a new tag and resubmit, not retag/force-move an
  existing release; this is already effectively enforced by the existing
  `UNIQUE (plugin_id, tag_name)` constraint on `plugin_versions`, so no new guard is needed. The
  failed attempt's row and its `review_checks` stay around as history rather than being
  overwritten.

## Architecture

`ProcessPluginVersion.pm` is extended in place (not replaced, and not split into per-check Minion
jobs — see "Orchestration model" below). After the existing download/extract/find-class/parse-
metadata steps (which already gate on class-file presence and `minimum_version`), it runs an
ordered list of check classes under a new `KohaPluginStore::Check::*` namespace:

- `KohaPluginStore::Check::PerlSyntax` (required)
- `KohaPluginStore::Check::ManifestCompleteness` (required)
- `KohaPluginStore::Check::DependencyAllowlist` (required)
- `KohaPluginStore::Check::PerlCritic` (non-required)
- `KohaPluginStore::Check::DocsPresence` (non-required)
- `KohaPluginStore::Check::TestsPresence` (non-required)
- `KohaPluginStore::Check::TranslatableTemplates` (non-required)
- `KohaPluginStore::Check::PluginTemplateWrapper` (non-required)
- `KohaPluginStore::Check::HardcodedCredentials` (non-required)
- `KohaPluginStore::Check::KohaMaxVersion` (recorded, non-gating)
- `KohaPluginStore::Check::GpgSignedTag` (recorded, non-gating)

Each implements a common interface: `->new(...)->run($extract_dir, $metadata, ...)` returning
`{ passed => bool, message => str }` — the same shape both `Koha::QA` and KPCA already use, which
also makes each check independently unit-testable against fixture plugin directories, and easy
to contribute back to KPCA piecemeal later.

### Orchestration model

Considered and rejected: fanning each check out to its own Minion job (an orchestrator job plus
one sub-job per check, joined via Minion's job-dependency mechanism), which would let checks run
in parallel and get independent retry/timeout policies. Rejected for now — real added complexity
(job-graph wiring, harder to trace one version's outcome across N job rows) that isn't justified
by a check catalogue this small, where only one check (`PerlSyntax`, see below) is genuinely
slow. Worth revisiting if the catalogue grows substantially or submission volume makes sequential
latency a real problem.

### Why only `PerlSyntax` needs sandboxing

`Koha::QA::PerlCritic` uses PPI to parse Perl statically — it never executes or `require`s the
file it's analyzing, so it's safe to run directly, unsandboxed, in the Minion worker process.
The same is true of every other check here: they're all static text/pattern scans, metadata
parsing, or GitHub API calls — none of them execute the plugin's code. `perl -c`, by contrast,
does execute `BEGIN` blocks and `use`-time imports at compile time, and plugins routinely `use
Koha::Plugins::Base` and other real Koha core modules the plugin-store's own environment doesn't
have — so `PerlSyntax` is the one check that needs both real module resolution and genuine
execution sandboxing.

### `PerlSyntax` sandbox mechanics

- Resolve the plugin's declared `minimum_version` (already a required, already-validated field by
  the time this check runs) to a Koha core git tag, and shallow-clone it
  (`git clone --depth 1 --branch <tag>`) into a shared cache directory keyed by tag, reused across
  submissions targeting the same Koha version. A `flock`-based per-tag lock avoids concurrent
  Minion jobs racing to clone the same tag simultaneously. The exact tag-naming convention and a
  fallback strategy for versions that don't resolve to an exact tag (e.g. nearest patch release
  under the same major.minor) need confirming against Koha's actual tagging scheme during
  implementation.
- One container invocation per version-check, not one per file: mount the cached checkout and the
  extracted plugin read-only, run a small wrapper script that loops `perl -I/koha/lib -cw` over
  every `.pm` file in the plugin and reports all results together. The container runs `--rm`,
  `--network none`, with capped memory/CPU and a hard wall-clock timeout.
- This is a genuinely new operational dependency: the Minion `worker` service (currently a plain
  Perl/Mojolicious container) needs `docker` CLI and socket access to run this. That's new
  infrastructure to provision, not just new application code.
- Full dynamic behavioural sandboxing (actually executing plugin hooks under `strace`/seccomp to
  catch obfuscated syscalls) was considered and explicitly deferred — see "Deferred work" below.

## Check catalogue detail

**Required (gate `INCOMPLETE` vs. `STRUCTURAL`/`CERTIFIED` — failing any means the version never
leaves `changes_requested`):**

1. **PerlSyntax** — sandboxed `perl -c` per `.pm` file, per above.
2. **ManifestCompleteness** — metadata hash has non-empty `version` and `license`. Note: today's
   metadata convention only populates name/description/author/minimum_version/version — `license`
   isn't something plugins currently declare. This check introduces a new required field going
   forward; it only applies to new version submissions, so nothing already published is
   retroactively affected.
3. **DependencyAllowlist** — static pattern scan (not dynamic execution monitoring, see "Deferred
   work") for `system()`, backticks/`qx//`, `exec()`, network module use (`IO::Socket`, `Net::*`,
   `LWP`, `HTTP::Tiny`), and filesystem access outside the plugin's own directory (absolute paths,
   `../` escapes via `open`/`unlink`/`rename`/`File::Copy`/`File::Path`). Same effort tier as
   `koha-qa`'s `forbidden_patterns` checks; a determined plugin could obfuscate around a pure
   pattern scan, which is the known limitation this trades off against not needing dynamic
   execution.

**Non-required, must ALL pass for `CERTIFIED`** (no scoring/weighting — §6 says "all
required=false checks also pass," so this is a second binary AND-gate, not a threshold):

4. **PerlCritic** — via `Koha::QA::PerlCritic`, starting with its shipped house `perlcriticrc`
   (revisit if it proves too strict for third-party plugin code once real submissions are seen).
5. **DocsPresence** — combines §6's two separate bullets ("Development.md/Contributing.md
   presence" and "documentation presence") into one check: passes if there's a
   `Development.md`/`CONTRIBUTING.md` *or* a README, rather than tracking them as two separate
   `review_checks` rows for what's fundamentally one "is this documented at all" question.
6. **TestsPresence** — a `t/` directory containing at least one `.t` file.
7. **TranslatableTemplates** — scan `.tt` files for Koha's translation-marker convention versus
   raw hardcoded English strings.
8. **PluginTemplateWrapper** — scan `.tt` files for the plugin content-wrapper include Koha
   expects plugin pages to use. The exact include name needs confirming against `Koha::Plugins`
   documentation during implementation.
9. **HardcodedCredentials** — heuristic pattern scan (API-key-shaped strings, `password => '...'`-
   style literals, etc.) — best-effort, not exhaustive.

**Recorded but non-gating** (§6 explicitly calls these "recommended, doesn't block" / "an input
signal," not part of the pass/fail set — they still get a `review_checks` row so they surface on
the plugin page, just don't participate in the `CERTIFIED` AND-gate):

10. **KohaMaxVersion** — `metadata->{maximum_version}` presence.
11. **GpgSignedTag** — GitHub API check of whether the tag's target commit is GPG-verified
    (`commit.verification.verified`).

## Tier computation

```
any required check failed?        → INCOMPLETE
all required passed,
  any non-required (gating) failed? → STRUCTURAL
all required passed,
  all non-required (gating) passed? → CERTIFIED
```

Checks 10–11 (`KohaMaxVersion`, `GpgSignedTag`) are recorded but excluded from this computation
entirely.

## Levels naming

§6's original level names ("Automated," "Static analysis") are dropped in favour of
`INCOMPLETE`/`STRUCTURAL`/`CERTIFIED`, borrowed from KPCA's vocabulary. KPCA's own middle tier,
`TRUSTED` (its 70–89% score band), is deliberately **not** carried over — reusing "trusted" here
would collide with §6's separate, out-of-scope "Trusted author" concept, which means something
completely different (a human's track record, not a code-quality score band). Keeping the
automated tier names free of "trust" language leaves that word available for whatever the future
author-reputation design lands on.

## Error handling

- **Check-infrastructure failure** (clone/network failure resolving or fetching the Koha tag,
  Docker daemon unavailable) is not the plugin's fault. The Minion job retries with backoff; once
  retries are exhausted, the version lands on a new `status` value, `check_error`, distinct from
  `changes_requested` — this needs its own badge in `templates/partial/table/plugins.html.ep`
  (existing badges: `submitted`/`checks_running`/`published`/`changes_requested`).
- **A plugin file that hangs the compiler** (e.g. an infinite `BEGIN` loop) hits the sandbox
  container's timeout — this **is** a plugin defect, so it's treated as `PerlSyntax` failing,
  landing on `INCOMPLETE`, not `check_error`.

## Testing

- Each `Check::*` class gets its own unit test against small fixture plugin directories (pass and
  fail cases), consistent with the existing test suite's shape.
- `PerlSyntax`'s actual `git clone`/`docker run` invocation sits behind a single injectable seam,
  following the existing typeglob-override pattern already used for
  `KohaPluginStore::GitHub::fetch_all_repos` — unit tests cover pass/fail/message-parsing logic
  without needing Docker present. A small number of separate, explicitly-gated integration tests
  (skipped unless Docker is actually available) exercise the real container path end-to-end.
- The task-level test (`t/task_process_plugin_version.t`) gets three new fixture plugins: one
  clean (→ `CERTIFIED`), one passing only required checks (→ `STRUCTURAL`), one failing a required
  check (→ `INCOMPLETE`) — asserting on both the resulting `review_checks` rows and
  `certification_tier`.

## Deferred work

- **Dynamic sandboxed behavioural auditing** for `DependencyAllowlist` — actually running the
  plugin under `strace`/seccomp inside the sandbox to catch obfuscated risky calls a static
  pattern scan would miss. §6 itself flags "broader automated security-vector scanning" as raised
  at the 2026 hackfest with no concrete tooling proposed yet; this design's static scan is a real
  improvement over the status quo (no such check exists today) but not a complete answer.
- **Author reputation and community/user ratings** — §6's "Trusted author" and "Community
  reviewed" ranks, reframed per "Scope and relationship to §6" above as separate, non-ladder
  concerns needing their own data model and their own design pass.
- **Upstreaming to KPCA** — the required-check set and the hard-gate-override concept (KPCA's
  weighted-average scoring has no equivalent) are worth proposing back to
  `koha-plugin-certification` given how much of its existing check catalogue this design already
  leans on for structure/inspiration.
