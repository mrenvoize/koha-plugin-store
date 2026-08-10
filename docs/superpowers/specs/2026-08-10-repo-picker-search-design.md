# Repo Picker Search & Pagination Fix — Design

**Status:** Approved for planning
**Relates to:** extends `docs/superpowers/specs/2026-08-07-repo-picker-design.md` (PR #18, still
open). Lands as new commits on `worktree-repo-picker` itself, not a new stacked PR — since #18
isn't merged yet, this is a fix to that feature, not a new one on top of it. `worktree-submission-pipeline`
(#19) and `worktree-home-page-rework` (#20) both already contain #18's current commits, so
they'll need rebasing onto the updated branch and force-pushing once this lands — confirm with
the user explicitly before doing that.

## Summary

Testing #18 against a real GitHub account (not `oauth_mock`) surfaced two problems:

1. The repo dropdown is unusable once an account has a lot of repos — plain `<select>`, no
   search.
2. Organization repos (`openfifth`, where most real plugins actually live) don't appear at
   all — only the account's own repos and a couple of individual-collaborator repos show up.

Root cause of (2): `GitHub::fetch_public_repos` fetches a single
`GET /user/repos?visibility=public&sort=updated&per_page=100` page. Once personal repo count
exceeds 100, less-recently-`pushed` org/collaborator repos get silently truncated off the end
by the `sort=updated` ordering. This is the same bug behind (1) — a proper fix needs real
pagination, which then makes "how do you find one specific repo in a paginated list" the actual
design question.

## Design constraint: don't eagerly fetch everything

An early version of this design proposed looping through every page up front so the picker
always has the complete list to search/filter over. Rejected: it turns every `/new-plugin` page
view into an unbounded number of GitHub API calls before the picker is even usable, for
accounts that may have very large repo counts. The interactive picker needs to stay genuinely
lazy — server-driven pagination and search, not a client-side filter over a pre-fetched blob.

## Two modes on `GET /api/v1/developer/repos`

GitHub's `/user/repos` (the affiliation-aware listing) has no text-search parameter — only
`page`/`per_page`/`sort`/`affiliation`/`visibility`. Filtering by typed text requires GitHub's
separate Search API (`/search/repositories`), which searches by qualifiers
(`user:`, `org:`, `in:name`), not by "repos this token is affiliated with". So the endpoint
gains two distinct code paths, chosen by whether a search term is present:

- **Browse** (`GET /api/v1/developer/repos?page=N`, no `q`): a new `GitHub::fetch_repos_page`
  passes through to
  `GET https://api.github.com/user/repos?affiliation=owner,collaborator,organization_member&sort=full_name&per_page=30&page=N`.
  This is the "scroll to load more" path.
- **Search** (`GET /api/v1/developer/repos?q=<term>&page=N`): a new `GitHub::search_repos` calls
  `GET https://api.github.com/search/repositories?q=in:name <term> user:<own login> org:<org1> org:<org2>...&per_page=30&page=N`,
  where the `user:`/`org:` qualifiers come from the developer's own GitHub login (already on
  the `Developer` model) plus their org memberships (see below). **Open implementation detail:**
  whether GitHub's search syntax combines multiple qualifiers with implicit OR or AND needs
  confirming against current GitHub search docs/behaviour before writing this; if OR-combination
  in a single query isn't reliable, fall back to one search call per qualifier (own login + each
  org) issued and merged/deduped in Perl, at the cost of juggling multiple pagination cursors.
- Both branches normalize their very different GitHub response shapes (`/user/repos` returns a
  bare array; `/search/repositories` returns `{ total_count, incomplete_results, items }`) into
  the same `{ repos: [...], has_more }` shape before reaching the controller. `has_more` is read
  off the GitHub response's `Link` header (`rel="next"` present or not) — accurate regardless of
  page-size edge cases, and identical logic works for both endpoints.
- Minimum query length of 2 characters before switching into search mode (shorter than that,
  keep serving browse results) — avoids firing a Search API call per keystroke on a
  single-character input.

The frontend never calls GitHub directly — the query/page params exist on this app's own `/api/v1/developer/repos`, proxied server-side, same as today.

## Session: caching org membership at login

Search mode needs the developer's org logins. Fetched once at real-OAuth login time
(`Controller::Auth::github`'s non-mock branch, right after the profile fetch) via a new
`GitHub::fetch_orgs($access_token)` (`GET /user/orgs`), stored as `$c->session->{github_orgs}`
— a separate session key alongside `github_access_token`, not a `developers` table column, same
pattern already established for the token itself. The `oauth_mock` login path skips this
(no real token to call GitHub with); search mode simply omits `org:` qualifiers for mock-logged-in
developers, which is fine since mock login exists to test other things.

## Frontend: Tom Select, server-driven

Loaded via CDN `<script>`/`<link>` scoped to `templates/new-plugin.html.ep`'s own
`content_for 'head'`/`'end'` blocks (matches how Bootstrap/boxicons are already loaded
elsewhere — no build step, nothing site-wide that only one page needs). The `<select
id="plugin_repo">` element itself now renders empty — the controller (`Plugins::add_form`) no
longer pre-fetches anything server-side; Tom Select populates it entirely via
`GET /api/v1/developer/repos` calls. This simplifies `add_form` back to just rendering the
template, and removes the need for the current server-rendered "no public GitHub repositories
found" branch — Tom Select's `render.no_results` option covers that same message for both "you
have zero repos" and "nothing matches your search", since both are just an empty result set from
the picker's point of view.

Behaviour:

- On first open (`preload: 'focus'`): load browse page 1.
- Typing (≥2 chars, debounced via Tom Select's `loadThrottle`, ~300ms): switch to search mode,
  `clearOptions()` and load search page 1 for that term.
- Clearing the search box back to empty: `clearOptions()`, switch back to browse mode, reload
  page 1.
- Scrolling the open dropdown near its bottom, with `hasMore` true and not already loading:
  request the next page for whichever mode is currently active and `addOption()` the results in
  (not a full reload) — Tom Select doesn't provide scroll-triggered pagination out of the box, so
  this is a small (~30-40 line) custom scroll listener on `dropdown_content`, tracking
  `{ currentQuery, currentPage, hasMore, isLoading }` in the page's own inline script.

Selecting an option still just sets the `<select>`'s value to the repo's `html_url`, same as
today — `new_plugin`'s form submission and server-side re-validation (next section) don't change
shape.

## Submission-time validation keeps the eager full-fetch — separately

`new_plugin`'s ownership re-check (`Controller::Plugins.pm`, currently line 143) calls
`fetch_public_repos` and greps the full result for the submitted `html_url`. Replacing that
function with the paginated one would break this check for anyone with 100+ affiliated repos —
worse, it's already broken today in exactly that way (a legitimate repo outside the first
`per_page=100` batch already gets wrongly rejected as "not in your list").

Fix: a new `GitHub::fetch_all_repos($access_token)`, used **only** by this validation path, that
loops browse-mode pages (same `affiliation`/`sort` as above) until `has_more` is false or a
safety cap (20 pages / 600 repos) is hit. This is a deliberately different cost/correctness
trade-off than the interactive picker: it runs once, server-side, at the moment of an actual
`POST /new-plugin` — already a multi-call, already-blocking operation (fetches the release,
downloads and extracts the `.kpz`, etc.) — where wrongly rejecting a legitimate submission
matters more than a few hundred extra milliseconds. Fixing this incidentally fixes the same
100-repo cap bug for submission, not just for browsing.

## OpenAPI spec

`GET /developer/repos` gains two optional query parameters, `q` (string) and `page` (integer,
default 1), and the response schema gains a required `has_more` (boolean) alongside the existing
`repos` array.

## Known limitation: collaborator-only repos aren't searchable

Search mode's `user:`/`org:` qualifiers cover repos the developer owns or that belong to an org
they're a member of — not repos where they're merely a collaborator on someone else's personal
account (the `axxapy`/`jhthorsen` examples raised). Those repos still appear fine in the plain
browse/scroll listing (which uses `affiliation=owner,collaborator,organization_member`), just
won't be found by typing their name. Accepted as-is for this pass; a future refinement could
accumulate "owners seen so far this session" from browse pages already loaded and fold them into
the search qualifiers, but that only helps for owners already scrolled past, so it's a partial
fix at best and not included here.

## Non-goals

- No browser-driven/JS test harness (Playwright etc.) added to this project. The picker's
  client-side behaviour (Tom Select init, scroll pagination, debounce) isn't covered by
  `Test::Mojo`-based tests, same as every other piece of inline JS in this app today — see
  Testing below for what does get covered.
- No mitigation for the collaborator-repo search gap (previous section).
- No change to how a selected repo is submitted/validated beyond swapping which `GitHub.pm`
  function backs the check (previous section) — `new_plugin`'s form shape, error messages, and
  the rest of the submission flow are untouched.

## Testing

- `t/github.t` gains coverage for `fetch_repos_page` (correct query params, `has_more` derived
  from the `Link` header), `search_repos` (query construction, GitHub's `items`-wrapped response
  shape normalized correctly), `fetch_orgs`, and `fetch_all_repos` (loops until `has_more` is
  false; stops at the safety cap). These need a test seam for the actual HTTP call (a small
  private `_get`-style sub, mirroring the existing seam pattern in
  `Controller::Auth::_get_oauth_token_p`/`_fetch_github_profile`), since GitHub.pm currently has
  no way to intercept its `Mojo::UserAgent` calls in tests.
- `t/api_developer_repos.t` extends to cover both modes: `?page=N` pass-through, `?q=term`
  switching to search, and `has_more` in the JSON response.
- `t/plugins_add_form.t`'s existing subtests (which assert on server-rendered `<option>`
  elements / the "no repos found" message) get narrowed to asserting the page renders an empty
  `#plugin_repo` mount point and includes the Tom Select assets — the actual data-population
  behaviour is exercised through `t/api_developer_repos.t` instead, since that's the real
  integration point `Test::Mojo` can meaningfully drive without a browser.
- `t/plugins_new_plugin.t` (submission validation) gets a case for a repo beyond a single
  browse page's worth of results, proving `fetch_all_repos` finds it where the old
  single-page `fetch_public_repos` would have wrongly rejected it.
