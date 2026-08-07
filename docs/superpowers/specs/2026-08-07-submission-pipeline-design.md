# Plugin Submission Pipeline Rework — Design

**Status:** Approved for planning
**Relates to:** `koha-plugin-store-spec.md` §4.3 (store-side ephemeral fetch/digest),
§5 (data model: `slug`, `status`, author/contributor fields), §6 (submission workflow,
tag-based release selection), §12 (developer-facing home page — separate piece); build
order step 3

## Summary

Replaces the current synchronous "fetch latest release → download → parse → confirm →
insert" pipeline (`Controller::Plugins::new_plugin`/`edit_form`, `Controller::Releases::new_release`,
and the shared `_download_plugin`/`_get_plugin_metadata` helpers) with an async pipeline:
the developer picks a repo and a specific tag, the store creates the `plugins`/
`plugin_versions` rows immediately (`status = 'submitted'`), and a Minion background job
does the actual download, extraction, metadata parsing, contributor lookup, and digest
computation — updating `status` as it goes. The developer watches progress on a new public
plugin detail page (`GET /plugins/:slug`) rather than waiting on a blocking request.

This builds directly on the already-merged repo-picker work (the developer's own GitHub
repos, ownership re-validated server-side) and closes the specific gaps identified against
the spec: no more permanent local `.kpz` cache, no more "always latest release," author/
contributors sourced from GitHub instead of self-reported, and a real `slug`/`status`
model.

Deliberately narrow, per discussion: no OpenAPI/API-first rewrite of the submission UI
(stays server-rendered for now), no §6 required-checks/levels pipeline (`review_checks`,
`levels`, `trusted_authors` — a distinctly-sized later piece), no Ed25519 signing (§4.3 —
bundled with the later publish-pipeline step, needs its own keypair-management design), and
no notification/email delivery on failure (parked as a future step).

## Synchronous vs. async split

**Synchronous** (`new_plugin`/`new_plugin_confirm`, `edit_form`/`new_release` — same
request/response shapes as today, just re-purposed):

1. Ownership check (unchanged — the repo-picker's existing re-validation).
2. Fetch the repo's recent releases from GitHub (now via the new app-level token, see
   below) and let the developer pick a specific tag — replacing "always fetch latest."
3. Require exactly one `.kpz` asset on the chosen release (unchanged check, just applied
   to the chosen release instead of always "latest").
4. Create `plugins` + `plugin_versions` rows immediately, `status = 'submitted'`, author
   captured for free from the release JSON's own `author` field (no extra API call).
5. Enqueue the `process_plugin_version` Minion job, redirect to `/plugins/:slug`.

**Async** (`process_plugin_version` Minion task, given a `plugin_version_id`):

1. Set `status = 'checks_running'`.
2. Download the `.kpz` to a temp file using the new app-level public-scoped token.
3. Extract it, find the plugin class file, parse `$metadata`.
4. Fetch the repo's contributors (best-effort — failure here doesn't block publish).
5. Compute `content_digest` (SHA-256) from the downloaded bytes, then discard the temp
   file — no permanent local cache, matching spec §4.3's "ephemeral fetch" model.
6. Set `status = 'published'` on success, or `status = 'changes_requested'` with a
   specific `error_message` on any content/validation failure.

The two-POST-round-trip shape of the current UI (`new_plugin` → step-2 template →
`new_plugin_confirm`) is kept, just re-purposed: step 2 used to be "confirm the parsed
metadata," it becomes "pick which release/tag to submit." `new_plugin_confirm` re-fetches
the chosen release server-side rather than trusting posted hidden fields for anything
security-relevant (the download URL in particular), re-validates ownership again (defense
in depth, consistent with the repo-picker's existing pattern), then creates rows and
enqueues the job. `edit_form`/`new_release` get the same treatment and get *simpler* in the
process — no more downloading and parsing all 5 previewed releases just to render a preview
table, since that parsing moved to async.

## Data model (migration version 3)

```sql
ALTER TABLE plugins ADD COLUMN slug TEXT UNIQUE;
ALTER TABLE plugins ADD COLUMN documentation_url TEXT;

ALTER TABLE plugin_versions ADD COLUMN status TEXT NOT NULL DEFAULT 'submitted';
  -- submitted | checks_running | published | changes_requested | deprecated
ALTER TABLE plugin_versions ADD COLUMN error_message TEXT;
ALTER TABLE plugin_versions ADD COLUMN content_digest TEXT;
ALTER TABLE plugin_versions ADD COLUMN author_username TEXT;
ALTER TABLE plugin_versions ADD COLUMN author_avatar_url TEXT;
ALTER TABLE plugin_versions ADD CONSTRAINT plugin_versions_plugin_id_tag_name_key
  UNIQUE (plugin_id, tag_name);

CREATE TABLE plugin_contributors (
    id                  SERIAL PRIMARY KEY,
    plugin_id           INTEGER REFERENCES plugins(id) ON DELETE CASCADE,
    github_username     TEXT NOT NULL,
    avatar_url          TEXT,
    contributions_count INTEGER,
    fetched_at          TIMESTAMPTZ DEFAULT now(),
    UNIQUE (plugin_id, github_username)
);
```

Notes:

- `status` lives on `plugin_versions`, not `plugins` (matches spec §5) — a plugin can have
  published versions and one still-processing version at the same time.
- `plugin_contributors` is plugin-level (not per-version), upserted on each new submission
  (refreshes `contributions_count`/`fetched_at` for existing rows rather than duplicating).
- `author_username`/`author_avatar_url` are a denormalized snapshot per version,
  deliberately **not** a `developer_id` foreign key — the person who cut the GitHub release
  may never have logged into this store. Purely a display/credit field; the trust model
  (§6, later) stays keyed to `developer_id`, the store-authenticated submitter, never to
  this.
- `UNIQUE (plugin_id, tag_name)` closes a real race: the existing app-level "already
  submitted" dedup check in `edit_form` is app-only and racy under a double-click or
  concurrent request.
- No `signature`/`signed_at`/`level`/`current_level_id` columns — out of scope here (see
  Non-goals).
- `plugins.name`/`class_name`/`description`/`author` need no nullability change — none
  carry a `NOT NULL` constraint today, only `UNIQUE`, and Postgres treats multiple `NULL`s
  as distinct under a unique constraint. So a row can exist with these all `NULL` between
  creation and the Minion job filling them in, with no migration needed for that alone.

## Slug generation

Derived from the GitHub repo's short name (kebab-cased) at creation time — not from the
plugin's own self-reported metadata name, since the slug must exist before metadata is
even parsed. Slugs are unique store-wide (not per-developer), so collisions are handled by
**insert-and-retry-on-conflict** (attempt insert, catch the unique violation, retry with
the next numeric suffix — `-2`, `-3`, ...) rather than check-then-insert, to avoid a race
between two developers submitting similarly-named repos at once. Bounded (10 attempts) —
exhausting them is effectively impossible with real repo names and would indicate
something else is badly wrong, surfaced as a submission error rather than looping forever.
Lives as a small `KohaPluginStore::Model::Plugin` helper so the controller stays thin.

## GitHub token

The current `github_user_access_token` config value is replaced with `github_app_token` —
a single fine-grained GitHub PAT scoped to **public repositories, read-only**. (OAuth App
client credentials can't be used as a bearer token for API calls — they only exist to
obtain per-user tokens during login — so this has to be a separate, dedicated credential;
confirmed with the user.) Used for all four new `GitHub.pm` calls: fetching releases,
fetching a specific release by tag, downloading the `.kpz`, and fetching contributors.

This constrained scope does double duty: the same token succeeding at downloading the
`.kpz` **is** the check that an anonymous Koha library (which has no GitHub credentials at
all) will actually be able to reach the same URL later. A download failure specifically due
to access restrictions (403/401, as opposed to a generic network error) gets a distinct
`error_message` — "GitHub reports this asset is not publicly accessible" — rather than a
generic download-failed message.

Config files (`koha_plugin_store.conf.example`, `koha_plugin_store.conf.docker.example`)
and `CLAUDE.md` get updated to describe the renamed key and its required scope.

## `GitHub.pm` additions

Same fully-qualified-call convention as the existing `fetch_public_repos` (module-level
subs, never imported, so tests can override via typeglob assignment):

- `fetch_releases($app_token, $owner_repo)` — the 10 most recent releases (tag, name,
  published date, assets, author) — a fixed page, no pagination UI, bumped from the
  current `edit_form`'s `per_page=5` since this now also serves first-time submission
  (more historical tags worth showing), not just adding a version to an existing plugin.
- `fetch_release_by_tag($app_token, $owner_repo, $tag_name)` — used at confirm-time to
  re-fetch authoritative data server-side.
- `download_kpz($app_token, $download_url, $dest_path)` — streams the asset to a temp
  path.
- `fetch_contributors($app_token, $owner_repo)` — repo-level contributors list.

## Minion wiring

New dependencies: `Minion`, `Minion::Backend::Pg`, registered against the app's existing
`pg` connection in `startup()`. New `lib/KohaPluginStore/Task/ProcessPluginVersion.pm`
(matches the spec's suggested `lib/.../Task/...` layout) registers the
`process_plugin_version` task, enqueued with a modest retry budget (`attempts => 3`,
Minion's default backoff) so transient infrastructure failures self-heal without manual
intervention.

Needs an actual worker process running — `script/koha_plugin_store minion worker` — which
the current synchronous pipeline never required. For Docker, a new sibling `worker` service
in `docker-compose.yml` alongside `app`; for `morbo` dev, a second terminal. Tests don't
need a real background worker: enqueue against the test Postgres, then drain the queue
synchronously in-process (Minion's standard test pattern).

## New route and detail page

```
GET /plugins/:slug   plugins#show   (NEW — public, no login required)
```

Discovery-facing, so no auth — shows the plugin's info, its versions with their
`status`/`error_message`, and the contributors list. While a version's status is
`submitted` or `checks_running`, the template includes a `<meta http-equiv="refresh"
content="5">` so the submitting developer sees progress without any new JS; it stops
appearing once status is terminal (`published`/`changes_requested`/`deprecated`).

## Error handling

The synchronous phase keeps today's pattern exactly — early-return with a stashed error
message, no DB writes (`_exit_with_error_message` already works this way).

The async job draws one distinction the current code never had to make: **content
problems vs. infrastructure problems**, since they mean different things to the developer
watching the detail page.

- **Content/validation failures** (invalid zip, no class file, no `$metadata`, missing
  `minimum_version`, or GitHub reporting the asset isn't actually publicly downloadable) —
  the job catches these itself with the same explicit success/failure checks the current
  synchronous code already uses (no new exception hierarchy — matches this codebase's
  existing style). Sets `status = 'changes_requested'` with a specific `error_message`. As
  far as Minion is concerned the job *succeeded* — there's nothing to retry, the submission
  itself is what's wrong.
- **Infrastructure failures** (DB drops mid-job, unexpected Perl death, GitHub having a bad
  day) — deliberately *not* caught by the job. They propagate as a real Minion job failure
  and get retried per the configured `attempts`; `status` stays at `checks_running`
  throughout, which is honest — still in progress, not the developer's fault.
- **Contributors fetch** is best-effort — failure is logged and skipped, never blocks
  publish.
- **Double-submission**: the existing app-level "already submitted" check in `edit_form`
  stays (a quick, friendly pre-check), but is now backed by the real DB constraint
  (`UNIQUE (plugin_id, tag_name)`) for the race window the app-level check alone can't
  close — a constraint violation is caught and shown as the same friendly message, not a
  crash.

## Testing

Follows existing conventions directly (`Test::Mojo`, `TestDB`, typeglob stubbing of
`GitHub.pm` functions):

- **New `t/task_process_plugin_version.t`** — the main new coverage. Enqueues the job
  against the real test Postgres, drains it synchronously in-process, covers the success
  path (`published`, digest set, author/contributors populated) and each failure mode
  individually (`changes_requested` with the right `error_message`), plus the
  access-restricted-download case specifically.
- Reshaped submission tests (`new_plugin`, `new_release`) assert a job gets enqueued and
  rows land with `status = 'submitted'`, rather than asserting on parsed metadata directly
  (that assertion moves to the task test).
- **New `t/plugins_show.t`** — detail page renders correctly for each status; the
  auto-refresh meta tag only appears for `submitted`/`checks_running`.
- `t/model_plugin.t` gains cases for slug generation and the collision-retry behavior.
- `t/github.t` gains the same no-token/edge-case coverage for the four new functions as
  `fetch_public_repos` already has; success-path HTTP behavior is exercised indirectly
  through the task tests via stubbing, matching existing precedent rather than mocking HTTP
  at the `GitHub.pm` level.

## Non-goals

- OpenAPI/API-first rewrite of the submission UI — stays server-rendered for now; the
  longer-term "UI as its own client app" direction is noted here but not acted on.
- §6's required-checks pipeline (`review_checks`, `levels`, `current_level_id`,
  `trusted_authors`) — a distinctly-sized later piece (spec build order step 5).
- Ed25519 signing (§4.3) — bundled with the later publish-pipeline step (build order step
  6); needs its own keypair-management design. `content_digest` is computed and stored now
  as pure infrastructure, but `signature`/`signed_at` stay out.
- Notification/email delivery when a submission fails — parked as a future step, per
  discussion.
- Backfilling `slug`/`author_username`/etc. on any pre-existing rows — this is early/WIP
  tooling with demo data reset via `reset_test_data`; no migration path for existing
  production data is needed.
- Any change to `/api/plugins` (`list_all`, the public discovery endpoint the Koha-side
  Vue client calls) — untouched by this piece.
