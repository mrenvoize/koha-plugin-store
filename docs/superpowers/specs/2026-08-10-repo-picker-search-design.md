# Repo Picker Search & Pagination Fix — Design

**Status:** Approved for planning
**Relates to:** extends `docs/superpowers/specs/2026-08-07-repo-picker-design.md` (PR #18, still
open). Lands as new commits on `worktree-repo-picker` itself, not a new stacked PR — since #18
isn't merged yet, this is a fix to that feature, not a new one on top of it. `worktree-submission-pipeline`
(#19) and `worktree-home-page-rework` (#20) both already contain #18's current commits, so
they'll need rebasing onto the updated branch and force-pushing once this lands — confirm with
the user explicitly before doing that. (The new migration this adds takes version 3 on
`worktree-repo-picker`; submission-pipeline's existing migration 3 renumbers to 4 as part of
that rebase.)

## Summary

Testing #18 against a real GitHub account (not `oauth_mock`) surfaced two problems:

1. The repo dropdown is unusable once an account has a lot of repos — plain `<select>`, no
   search.
2. Organization repos (`openfifth`, where most real plugins actually live) don't appear at
   all — only the account's own repos and a couple of individual-collaborator repos show up.

Root cause of (2): `GitHub::fetch_public_repos` fetches a single
`GET /user/repos?visibility=public&sort=updated&per_page=100` page. Once personal repo count
exceeds 100, less-recently-`pushed` org/collaborator repos get silently truncated off the end
by the `sort=updated` ordering.

## Design history: two rejected approaches, and why

Two earlier shapes of this fix were considered and dropped before landing on the one below —
worth recording so the reasoning isn't lost:

- **Eagerly fetch every page on every `/new-plugin` view.** Fixes the truncation bug directly,
  but turns every page view into an unbounded number of GitHub API calls before the picker is
  even usable. Rejected for making a common, cheap page load slow and GitHub-rate-limit-hungry
  for no reason most visits don't need.
- **Server-driven pagination for browsing + GitHub's Search API for typed search.** Avoids the
  eager fetch, but Search API's `user:`/`org:` qualifiers don't cover repos where the developer
  is merely a collaborator on someone else's personal account (this account's `axxapy`/`jhthorsen`
  examples) — those would be browsable but not searchable. It also adds a second GitHub API
  surface with its own tighter rate limit, qualifier-syntax uncertainty, and a chunk of custom
  frontend JS (scroll-triggered pagination, debounce, mode-switching between browse and search).

## The design: an explicit, cached, manually-refreshed repo list

Fetch everything — but only when the developer deliberately asks for it, not on every page
view. Once fetched, browsing and searching both happen against that cached list locally, with
no further GitHub calls and no server round-trip per keystroke.

### Storage

Two new columns on `developers` (migration version 3 on this branch):

- `cached_repos` — JSONB array of `{full_name, html_url}`, same shape the picker has always
  used.
- `cached_repos_fetched_at` — timestamp of the last successful refresh.

### Refreshing the cache

A new `GitHub::fetch_all_repos($access_token)` loops
`GET /user/repos?affiliation=owner,collaborator,organization_member&sort=full_name&per_page=100&page=N`
until a page returns fewer than `per_page` results, or a safety cap (20 pages / ~2000 repos) is
hit. Because it now correctly covers `affiliation=organization_member` across *all* pages, this
directly fixes the missing-`openfifth`-repos bug — no Search API needed to make org repos
visible, they were always included in this listing, just previously truncated.

A new route, `POST /developer/repos/refresh`, runs `fetch_all_repos` and writes the result plus
current timestamp onto the developer's row, then redirects back to `/new-plugin`.

### The picker page

`GET /new-plugin` shows "Repo list last refreshed at `<cached_repos_fetched_at>` —
[Refresh]" above the dropdown (or "No repos loaded yet — click Refresh to fetch your GitHub
repos" if `cached_repos` is still null). `GET /api/v1/developer/repos` goes back to being
trivial — it returns the developer's `cached_repos` array as-is, no `q`/`page` params, no
`has_more`.

Tom Select (loaded via CDN `<script>`/`<link>`, scoped to this template's own
`content_for 'head'`/`'end'` blocks — matches how Bootstrap/boxicons are already loaded
elsewhere, no build step) is initialized with that array directly as its option list. No
`load` callback, no debounce, no scroll-triggered pagination — Tom Select filters a local array
of this size (at most a couple thousand entries, realistically a few hundred) entirely
client-side, instantly, for free. This removes essentially all the custom JS the Search-API
version would have needed.

### First-ever visit

A brand-new developer (`cached_repos` still null) gets the fetch triggered automatically,
once, the first time they load `/new-plugin` — so the picker isn't uselessly empty before
they've discovered the Refresh button. Every visit after that is pure cache-plus-manual-refresh,
identical to everyone else; there's nothing implicit about *staying* fresh, only about not
starting from a dead end.

### Submission-time validation stays live, deliberately

`new_plugin`'s ownership re-check (`Controller::Plugins.pm`, currently line 143) keeps calling
`fetch_all_repos` fresh at the moment of `POST /new-plugin`, rather than reading
`cached_repos`. This is a deliberate split: the picker's cache is a convenience the developer
controls the freshness of, but the security-sensitive check — "is this really still one of your
repos?" — shouldn't be foolable by a stale cache (e.g. a repo removed from an org, made
private, or deleted since the developer's last refresh). One extra live GitHub round-trip at
actual submission time is an acceptable cost on an already multi-call, already-blocking
operation (it also fetches the release, downloads and extracts the `.kpz`, etc.); it isn't
paid on every page view the way the rejected eager-fetch approach was.

## What this removes from the earlier design

No `search_repos`, no org-membership session caching (`github_orgs`), no `has_more`/`Link`-header
parsing on the interactive path, no OpenAPI `q`/`page` params, no scroll-pagination JS. All of
that existed to make browsing lazy while still supporting search — moot once browsing is
against an already-fetched local cache.

## Non-goals

- No automatic background refresh (cron, webhook-driven invalidation on GitHub repo
  create/push, etc.) — refresh is a manual, developer-initiated action, full stop.
- No incremental/delta sync on refresh — each refresh is a full re-fetch via
  `fetch_all_repos`, replacing `cached_repos` wholesale. Simpler, and refresh is rare enough
  that re-fetching everything isn't a real cost.
- No browser-driven/JS test harness (Playwright etc.) added to this project — Tom Select's
  client-side filtering isn't covered by `Test::Mojo`-based tests, same as every other piece of
  inline JS in this app today.

## Testing

- `t/github.t` gains coverage for `fetch_all_repos` (loops until a short page; stops at the
  safety cap), using a test seam for the actual HTTP call (a small private `_get`-style sub,
  mirroring the existing seam pattern in `Controller::Auth::_get_oauth_token_p`/
  `_fetch_github_profile`), since `GitHub.pm` currently has no way to intercept its
  `Mojo::UserAgent` calls in tests.
- A new `t/developer_repos_refresh.t` covers `POST /developer/repos/refresh`: requires login;
  populates `cached_repos`/`cached_repos_fetched_at`; redirects to `/new-plugin`.
- `t/api_developer_repos.t` simplifies to match the trivial endpoint: returns whatever's in
  `cached_repos` (including the empty/null case), no pagination/search params to exercise.
- `t/plugins_add_form.t` gains a case for the first-visit auto-fetch (`cached_repos` null →
  triggers a fetch and populates it) alongside its existing coverage.
- `t/plugins_new_plugin.t` (submission validation) keeps proving the live-fetch path works
  correctly for repos beyond a single page — and gains a case showing a submission succeeds
  even when `cached_repos` is stale/empty, since validation doesn't read it.
