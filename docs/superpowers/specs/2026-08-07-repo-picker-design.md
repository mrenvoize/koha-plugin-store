# Repo Picker — Design

**Status:** Approved for planning
**Relates to:** `koha-plugin-store-spec.md` §4.1 ("submission constrained to repos the developer's own OAuth token can see"); build order (§11) step 3

## Summary

Replaces the free-text repo URL field in plugin submission with a picker constrained to
repositories the logged-in developer's own GitHub OAuth token can see, and — critically —
enforces that constraint server-side, not just in the UI. Also adds `GET
/api/v1/developer/repos`, the first real (non-scaffold) use of the OpenAPI plugin wired up
in the sibling branch this stacks on.

Deliberately narrow, per the earlier scope discussion: no other submission-flow changes
(plugin `slug`, `documentation_url`, a proper `status` state machine) in this piece.

## Retaining the developer's GitHub token

The OAuth login work (already merged into this stack) uses the developer's access token
exactly once, to fetch their profile at login, then discards it — there was nothing else
that needed it. This feature is the first thing that does: listing repos requires calling
GitHub's API again, later, as the developer.

`log_in_developer($c, $developer, $access_token = undef)` gains a second, optional
parameter, stored as `$c->session->{github_access_token}` — a separate session key, not
merged into `session->{developer}`, since it isn't an actual `developers` table column.
The real GitHub flow (`Controller::Auth#github`) passes it; the `oauth_mock` path doesn't,
so mock-logged-in developers simply have no token and the picker shows an empty state for
them (expected — mock login exists to test other things). Logging out already expires the
whole session, so no separate cleanup is needed.

Accepted tradeoff, discussed explicitly: this app runs over plain HTTP, so the token
travels in a signed-but-unencrypted cookie. This doesn't introduce a new class of exposure
— the existing session already carries the developer's identity the same way — it just adds
a more sensitive value to something already accepted as good enough for this stage of the
project.

## OAuth scope

No new scope requested beyond what login already asks for. GitHub's default (unscoped)
token already lists a user's *public* repos via `GET /user/repos`. Plugins submitted to
this store become publicly discoverable/installable anyway, so there's no use case for
picking a private repo — and requesting the broad `repo` scope (read/write to everything,
public and private) for a feature that only needs public listings would be a needless,
visible-to-the-developer permission escalation on GitHub's consent screen.

## The endpoint: `GET /api/v1/developer/repos`

Built via the OpenAPI plugin now properly available in this stack (mounted at `/api/v1`,
currently serving only `/ping`) — the first real endpoint to use it, as discussed
separately from this feature.

Auth is enforced through OpenAPI's own per-operation `security` mechanism
(`Mojolicious::Plugin::OpenAPI::Security`), not a manual in-controller check — confirmed
working with this app's OpenAPI 3.0-style spec via a standalone test before committing to
this approach (it's demoneted as "still EXPERIMENTAL" upstream, but functions correctly: an
unauthenticated request never reaches the controller action, 401s automatically). `spec.yaml`
declares a `session_auth` security scheme (`type: apiKey, in: cookie` — describing this
app's existing signed-cookie session, not a new auth mechanism) and applies it to this one
operation; the app registers a matching callback at plugin-registration time that checks
`$c->session->{developer}`.

```yaml
components:
  securitySchemes:
    session_auth:
      type: apiKey
      in: cookie
      name: mojolicious
paths:
  /developer/repos:
    get:
      operationId: developerRepos
      x-mojo-to: api#developer_repos
      security:
        - session_auth: []
      responses:
        '200':
          description: The developer's public GitHub repositories
          content:
            application/json:
              schema:
                type: object
                required: [repos]
                properties:
                  repos:
                    type: array
                    items:
                      type: object
                      required: [full_name, html_url]
                      properties:
                        full_name: { type: string }
                        html_url: { type: string }
        '401':
          description: Not logged in
          content:
            application/json:
              schema: { type: object }
```

```perl
$self->plugin( 'OpenAPI', {
    url      => $self->home->child(qw(lib KohaPluginStore OpenAPI spec.yaml)),
    route    => $self->routes->any('/api/v1'),
    security => {
        session_auth => sub {
            my ( $c, $definition, $scopes, $cb ) = @_;
            return $c->$cb() if $c->session->{developer};
            return $c->$cb('Not logged in');
        },
    },
} );
```

`Controller::Api::developer_repos` itself does no auth check (the framework already
guaranteed a logged-in developer by the time it runs) — it only needs to handle a missing
`github_access_token` (mock-logged-in developer): return an empty `repos` list, not an
error.

## Shared fetch logic

Both this endpoint and the submission form need the same GitHub call, so it lives in one
place rather than being duplicated: a new plain module, `KohaPluginStore::GitHub`, with a
single function `fetch_public_repos($access_token)` — calls `GET
https://api.github.com/user/repos?visibility=public&sort=updated&per_page=100` with the
given token, returns an arrayref of `{ full_name, html_url }` (or `[]` on any failure —
missing token, network error, revoked token, rate limit). Kept as an ordinary package sub
(not a Mojolicious helper) specifically so tests can override it via typeglob assignment —
the same pattern already established for `Controller::Auth`'s `_get_oauth_token_p`/
`_fetch_github_profile`, and reused again in this feature's own tests.

## Submission form integration

No client-side JS fetch. `Controller::Plugins::add_form` calls
`KohaPluginStore::GitHub::fetch_public_repos($c->session->{github_access_token})` directly
when rendering the "New Plugin" page and stashes the result — consistent with how
`edit_form` already makes a live, uncached GitHub call at render time. `new-plugin.html.ep`'s
free-text `plugin_repo` input becomes a `<select>` built from that list
(`full_name` as the label, `html_url` as the value — matching what the free-text field
already expected). An empty list or a failed fetch shows a message in place of the dropdown
("No public GitHub repositories found for your account" or a fetch-failed message) — no
crash, and no free-text fallback (see below).

## Real enforcement, not just UI

A dropdown alone doesn't stop someone POSTing an arbitrary `plugin_repo` value directly,
bypassing the form entirely. `Controller::Plugins::new_plugin` re-fetches the developer's
repo list server-side (same shared function) and rejects the submission (rendering
`new-plugin.html.ep` again with an error) if the posted `plugin_repo` isn't a member of it.
This — not the dropdown — is what actually closes the gap spec §4.1 describes: a developer
can no longer submit a plugin for a repo they don't control, even by hand-crafting a
request. This means two live GitHub calls per submission attempt (one at form-render, one
at submit-validation) — a known, accepted minor inefficiency, not fixed here; no caching
layer is being added, matching existing precedent in this codebase.

Deliberately no free-text fallback if the GitHub call fails or the desired repo isn't in
the first page of results (pagination beyond 100 repos isn't handled) — a fallback would
defeat the point of the feature. The honest failure mode is "can't submit right now," not
"quietly let you bypass the check."

## Non-goals

- GitLab/Forgejo — out of scope, as with the login work itself.
- Any of spec §5's levels/review/trust/rating schema, or `plugins`/`plugin_versions`
  schema changes (`slug`, `documentation_url`, `status` state machine).
- Pagination beyond GitHub's first 100 results per developer.
- Converting any *other* existing endpoint (`/api/plugins`) to OpenAPI — this PR is the
  first real proof of the pattern on new work only, per the earlier discussion.
