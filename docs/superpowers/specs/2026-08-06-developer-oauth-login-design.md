# Developer OAuth Login — Design

**Status:** Approved for planning
**Relates to:** `koha-plugin-store-spec.md` §4.1, §4.2, §5 (partial); build order (§11) step 2

## Summary

Replaces the app's current username/password developer login with GitHub OAuth,
using `Mojolicious::Plugin::OAuth2`. This is a full cutover, not a parallel
option: the `users` table, `Model::User`, and the password login/register UI
are removed, replaced by a `developers` table keyed on GitHub identity.

This is a deliberately narrow slice of the target spec. It does **not** build
the rest of §5's schema (levels, review, trust, ratings tables) or the
repo-picker (`GET /api/v1/developer/repos`) — those are separate future
pieces (build-order steps 3, 4, 7, 8), and nothing in this slice depends on
them existing yet.

## Scope

**In scope:**
- GitHub OAuth login (registration happens implicitly on first login)
- `developers` table, replacing `users`
- `plugins.developer_id`, replacing `plugins.user_id`
- Session/ownership call-site updates across controllers and templates
- Fixing a live ownership gap in `Controller::Releases::new_release`
  (see "Additional fix" below)
- Config-driven provider list (`oauth_providers` in `koha_plugin_store.conf`),
  even though only a `github` entry is populated now

**Out of scope (explicitly deferred):**
- GitLab/Forgejo providers — the config/provider abstraction supports adding
  them later as custom `Mojolicious::Plugin::OAuth2` provider entries, but
  none are implemented in this slice
- `GET /api/v1/developer/repos` and the submission-form repo-picker —
  lands with build-order step 3 (plugin/version submission), since nothing
  uses it until then
- A dev-only login bypass — local/Docker dev registers a real GitHub OAuth
  App, same pattern as the existing `github_user_access_token` config
- Any part of §5's levels/review/trust/rating schema
- Ownership *transfer* or multi-maintainer history for a plugin — out of
  scope and undefined by the spec; see "Non-goals" below

## Data model

New migration (appended as the next numbered step in `migrate.pm`'s
`__DATA__` migrations):

```sql
-- 2 up
CREATE TABLE developers (
    id                 SERIAL PRIMARY KEY,
    oauth_provider_key TEXT NOT NULL,
    provider_user_id   TEXT NOT NULL,
    username           TEXT NOT NULL,
    avatar_url         TEXT,
    created_at         TIMESTAMPTZ DEFAULT now(),
    UNIQUE (oauth_provider_key, provider_user_id)
);

ALTER TABLE plugins DROP COLUMN user_id;
ALTER TABLE plugins ADD COLUMN developer_id INTEGER REFERENCES developers(id) ON DELETE CASCADE;

DROP TABLE users;

-- 2 down
CREATE TABLE users (
    id       SERIAL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    email    TEXT UNIQUE NOT NULL
);

ALTER TABLE plugins DROP COLUMN developer_id;
ALTER TABLE plugins ADD COLUMN user_id INTEGER REFERENCES users(id) ON DELETE CASCADE;

DROP TABLE developers;
```

`developers` matches spec §5 exactly — no email column (avoids
account-linking bugs from an email changing on the provider side), keyed on
`(oauth_provider_key, provider_user_id)` since usernames aren't guaranteed
unique across providers (relevant once a second provider is added).

## Model layer

- **Delete** `Model::User`, `t/model_user.t`.
- **Add** `Model::Developer` (`_table => 'developers'`,
  `_columns => [qw(id oauth_provider_key provider_user_id username avatar_url created_at)]`),
  with a `find_or_create_from_oauth({ oauth_provider_key, provider_user_id, username, avatar_url })`
  method: looks up by `(oauth_provider_key, provider_user_id)`; creates on
  first login; on an existing match, updates `username`/`avatar_url` if
  they've changed on the provider side (people rename themselves on GitHub).
- `Model::Plugin`'s `_columns` changes `user_id` → `developer_id`.

## Provider configuration

A small `oauth_providers` list in `koha_plugin_store.conf`, matching the
shape sketched in spec §4.1 (translated to this app's Perl-hashref config
format rather than YAML):

```perl
oauth_providers => [
    {
        key           => 'github',
        kind          => 'github',
        display_name  => 'GitHub',
        client_id     => 'YOUR_CLIENT_ID',
        client_secret => 'YOUR_CLIENT_SECRET',
    },
],
```

Loaded once at startup into `Mojolicious::Plugin::OAuth2`'s own `providers`
config — for `kind => 'github'`, that's the plugin's built-in `github`
provider definition (just needs `key`/`secret`); a future `kind => 'gitlab'`
or `kind => 'forgejo'` would map to a custom provider block
(`authorize_url`/`token_url`, or `well_known_url` for OIDC-compatible
instances like Forgejo) — not built now, since nothing needs it yet, but the
config shape doesn't need to change when it is.

## OAuth flow

Uses `Mojolicious::Plugin::OAuth2`, registered in `startup()`. New
`Controller::Auth`, one action:

- `GET /auth/github` (`Controller::Auth#github`): calls
  `$c->oauth2->get_token_p('github')->then(sub {...})->catch(sub {...})`.
  - On the *initial* hit (no `code`/`state` params yet), the plugin redirects
    the browser to GitHub's authorize page itself — no separate `/start`
    route or hand-rolled redirect/CSRF-state code needed, the plugin owns
    that entirely.
  - On the *callback* hit (GitHub redirects back to this same URL with
    `code`/`state`), the promise resolves with the token data instead.
  - Confirmed against `Mojolicious::Plugin::OAuth2` v2.02's own POD: this
    single-action redirect-then-resolve behaviour is exactly how
    `get_token_p` is documented to work, not an assumption.
- On success, fetch `GET https://api.github.com/user` with the access token
  (blocking `Mojo::UserAgent->new->get(...)`, matching this app's current
  style — the broader move to non-blocking controllers is the already-agreed
  separate future follow-up), extract `{id, login, avatar_url}`, call
  `Model::Developer->new(pg => $c->pg)->find_or_create_from_oauth({
  oauth_provider_key => 'github', provider_user_id => $id, username => $login,
  avatar_url => $avatar_url })`, log the developer into the session, redirect
  to `/my-plugins`.
- Requesting no OAuth scopes beyond GitHub's default (public profile only) —
  `developers` doesn't store email, so `user:email` scope isn't needed.
- The token-exchange and profile-fetch calls are isolated into small,
  separately-callable methods so tests can stub them directly instead of
  mocking HTTP (see Testing, below).

## Session and existing call-site changes

Session key renames from `session->{user}` to `session->{developer}`,
following through everywhere "user" terminology is being retired:

- `KohaPluginStore.pm`: the `user_authenticated` route condition and the
  `logged_in_user` helper. `logged_in_user` looks the developer up by `id`
  (not `username` — not guaranteed unique once a second provider exists).
- `Controller::Plugins.pm`: `my_plugins`, `add_form`, `edit_form`,
  `new_plugin_confirm` — `session->{user}` → `session->{developer}`,
  `plugin->user_id` → `plugin->developer_id`.
- `templates/partial/table/plugins.html.ep`: ownership check
  (`logged_in_user->id eq $plugin->user_id` → `$plugin->developer_id`).
- `templates/layouts/default.html.ep`, `templates/partial/auth_menu.html.ep`:
  unaffected beyond the "Register" link removal below, since they go through
  the `logged_in_user` helper rather than touching the session directly.

## Additional fix folded in: `Releases.pm` ownership gap

`Controller::Releases::new_release` currently has **no auth or ownership
check at all** — it's not gated by `user_authenticated`, and doesn't compare
the target plugin's owner against the logged-in developer. Since this slice
is already touching every `user_id`/`developer_id` call site, fold in:

- Route gated behind `->requires( user_authenticated => 1 )`, matching the
  pattern already used for `/my-plugins` and `/new-plugin`.
- An ownership check inside `new_release`, matching the one `edit_form`
  already does: 404 if the plugin doesn't exist, 401 if
  `$c->session->{developer}->{id} != $plugin->developer_id`.

This is a pre-existing gap, not something introduced by this slice — noted
here because it's directly adjacent to the code already being changed.

## UI changes

- `templates/login.html.ep`: form replaced with a single "Log in with
  GitHub" link to `/auth/github`.
- `templates/register.html.ep`: deleted — first GitHub login *is*
  registration, there's no separate signup step.
- `templates/partial/auth_menu.html.ep`: "Register" list item removed.
- Routes: `GET/POST /login` and `GET/POST /register` (password forms)
  removed; `GET /login` now renders the GitHub-login landing page (kept at
  the same URL so the nav menu's existing `/login` link doesn't change);
  `GET /auth/github` added; `GET /logout` unchanged.

## Testing approach

Automated tests can't hit real GitHub. The controller isolates the two
GitHub-specific calls (token exchange, profile fetch) into separately
callable methods so tests can stub them directly:

- `Model::Developer`: unit-test `find_or_create_from_oauth` directly against
  the test Postgres — create-on-first-call, update-on-repeat-call-with-
  changed-username, no HTTP involved.
- `Controller::Auth`: test the callback path by stubbing the profile-fetch
  method to return fixed `{id, login, avatar_url}` data and asserting the
  resulting session state and redirect, without needing `get_token_p` to
  actually talk to GitHub.
- `Controller::Releases::new_release`: test the new 401/404/success paths
  with a seeded developer and plugin.
- The real end-to-end redirect-to-GitHub-and-back flow is a manual smoke
  test against a real GitHub OAuth App registered for local dev, not part of
  the automated suite.

## Seed data

`reset_test_data` creates synthetic `developers` rows directly (fake
`provider_user_id` values, e.g. `'1001'`, `'1002'`), the same pattern used
today for fake `users` rows — it can't fabricate a real OAuth login. Existing
demo plugins' `user_id` references become `developer_id`.

## Non-goals

- **Ownership transfer / multi-maintainer history.** A plugin's `developer_id`
  is set once at creation and never changes in this design — matching
  today's behaviour and spec §5's schema (which also has no
  transfer/history table). If a plugin gains a new maintainer over time,
  that's unsupported by both the current app and the target spec; it isn't
  designed here because there's no consuming feature or spec definition for
  it yet, not because it was overlooked.
- **A store-level admin/reviewer role.** Confirmed the current app has no
  admin/permission concept at all — "admin" is just a seeded username, not a
  role. Dropping password login therefore removes no functional admin
  capability. But the target spec's later tables (`trusted_authors.added_by_admin_id`,
  `human_reviews.reviewer_id`) assume *some* privileged identity exists, and
  neither `koha-plugin-store-spec.md` §5 nor its §2 "Still open" list defines
  who that is or how someone gets that status. Flagging this now so it isn't
  lost before build-order steps 7-8 need an answer — not solving it here.
