# Plugin Details/Edit Page Merge — Design

**Status:** Approved for planning
**Relates to:** immediate bug report — a developer whose submission reaches
`changes_requested` has no way to see which checks failed or why. Surfacing that detail
turned into a broader page redesign once the existing "Edit" page was examined (see
"Prior state and discovered bugs" below).

## Summary

Today `GET /plugins/:slug` (public, `Controller::Plugins::show`) and
`GET /plugins/edit/:id` (owner-only, `edit_form`) are two separate pages that repeat much
of the same information (plugin name/description, the versions/releases table). The show
page's per-version "Checks" column only ever displayed the generic
`error_message` ("One or more required checks failed -- see the version page for
details"), never the individual `review_checks` rows that would tell a developer what to
actually fix. Editing a plugin's own name/description/repo/author is also currently
non-functional (see below).

This design merges the two pages into one tabbed page at `/plugins/:slug` — **Details**
and **Releases** — with editing moved into a modal on the Details tab, and per-check
detail surfaced in the Releases tab for owners.

## Prior state and discovered bugs

- The show page's Releases-equivalent (its single "Versions" table) already stashes
  `error_message` per version but never `review_checks` rows — the immediate bug this
  design fixes.
- The current `edit.html.ep` submits via `form_for 'new-plugin'`, which routes to
  `Controller::Plugins::new_plugin` — an action that validates a *GitHub repo picker*
  selection and creates a *new* plugin/release. It does not update `name`, `description`,
  `repo_url`, or `author` on an existing plugin. **Editing an existing plugin's details is
  currently non-functional.** This design replaces it with a real update action.

## Section 1: Routes & controller

- New route: `POST /plugins/:slug/edit` → new `update_plugin` action.
- Removed: `GET /plugins/edit/:id` route and the `edit_form` action/template.
- `show` gains a conditional, owner-only fetch of `github_releases`
  (`KohaPluginStore::GitHub::fetch_releases`, the same call `edit_form` made) — only
  executed when the session's developer id matches `$plugin->developer_id`. Public
  visitors never trigger a live GitHub call.
- `templates/my-plugins.html.ep` / `partial/table/plugins.html.ep`: the separate "Edit"
  link is removed; the plugin title link stays `/plugins/:slug` (editing happens from
  there now, via the modal).

## Section 2: Template structure

One template, `templates/plugins/show.html.ep`, with two Bootstrap tabs:

**Details tab** (display-first):
- Plugin name, description, repo URL, author — read-only display.
- Contributors list (moved here from its current standalone section on the show page).
- Owner-only "Edit" button opens a modal pre-filled with the same four fields, posting to
  `POST /plugins/:slug/edit`.

**Releases tab:**
- *Public visitors* see only `status = 'published'` versions, each showing its
  `certification_tier` badge and full `review_checks` detail (check name, required/
  advisory, pass/fail, message) — the same level of detail as owners get, just scoped to
  published versions. No GitHub-available-releases section.
- *Owners* (session developer id matches `plugin->developer_id`) see all versions
  regardless of status — including `changes_requested`/`checks_running`/`check_error` —
  each with the same full certification/check detail, plus the existing
  GitHub-available-releases section ("Add this release" for tags not yet submitted).
- Non-owner logged-in developers are treated identically to public visitors.
- The controller keeps this simple: `show` always fetches all versions and their checks;
  the *template* filters to `published`-only when the viewer isn't the owner. `github_releases`
  is only fetched (and only stashed) for owners, per Section 1.

## Section 3: Update validation & error handling

`update_plugin`:
- Returns 404 if the plugin doesn't exist, 401 if the session developer isn't the owner
  (mirrors `edit_form`'s existing checks).
- Validates that `name`, `description`, `repo_url`, and `author` are all non-blank —
  matching the bar the current edit form already implies via its HTML `required`
  attributes; no new validation rules are introduced.
- On a blank required field: re-renders `plugins/show` directly (not a redirect) with an
  `errors` stash for a banner, the Details tab active, the edit modal pre-opened, and the
  modal's fields pre-filled with what the user just submitted (so edits aren't lost). To
  avoid duplicating `show`'s data-loading (versions/contributors/checks/github_releases),
  that loading is factored into a small private helper both `show` and `update_plugin`'s
  failure path call.
- The existing `_exit_with_error_message` helper (used by `new_plugin`/`new_plugin_confirm`)
  is not reused here — it hard-codes rendering `new-plugin-step2`, a template unrelated to
  this flow. `update_plugin` handles its own error rendering as described above.
- On success: updates the plugin via the model's existing generic `update()` method, then
  redirects (a plain redirect, no error state) to `/plugins/:slug`.

## Section 4: Testing

Following the existing `t/*.t` pattern (Test::Mojo against the app, `TestDB` reset per
subtest):

- **`t/plugins_show.t`** (extends the existing file, which already covers the
  auto-refresh and per-check-detail bugfix cases): add subtests for the merged page —
  public visitor sees only `published` versions with no GitHub-available section and no
  edit affordance; owner sees all versions (including `changes_requested` with full check
  detail) plus the GitHub-available-releases section and an edit control; a logged-in
  developer who is not the owner is treated like a public visitor.
- **`t/plugins_update.t`** (new): covers `POST /plugins/:slug/edit` — 404 for unknown
  slug, 401 for non-owner, blank-field validation re-renders `show` with `errors` stashed
  and submitted values preserved, and a valid update persists and redirects to
  `/plugins/:slug`.
- No existing test file covers `edit_form`/`edit.html.ep` today (confirmed: no
  `t/plugins_edit.t` exists), so nothing needs to be retired — only the two additions
  above.

## Out of scope

- Any change to the check pipeline itself (check catalogue, tier computation) — this
  design only surfaces existing `review_checks`/`certification_tier` data that the
  check-pipeline design already produces.
- Author reputation, community ratings, or any change to `certification_tier` semantics.
