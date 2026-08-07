# Repo Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the free-text repo URL field in plugin submission with a picker constrained to the logged-in developer's own public GitHub repositories, enforced server-side, and add `GET /api/v1/developer/repos` as the first real use of the OpenAPI plugin.

**Architecture:** The developer's GitHub OAuth access token, previously discarded after login, is now kept in session. A new plain module (`KohaPluginStore::GitHub`) owns the one GitHub call this feature needs (`GET /user/repos`), called by fully-qualified name everywhere (never imported) so tests can override it by simple typeglob assignment. The new API endpoint uses OpenAPI's own per-operation `security` mechanism for auth, not a manual in-controller check. The submission form calls the same module server-side to render a dropdown, and the submission handler re-calls it to reject any repo not actually in the developer's list — the dropdown is a convenience, this check is the real boundary.

**Tech Stack:** Mojolicious, `Mojolicious::Plugin::OpenAPI` (+ its bundled `::Security` plugin), `Mojo::UserAgent`, `Test::Mojo`.

## Global Constraints

- No new OAuth scope requested — GitHub's default (unscoped) token already lists public repos via `GET /user/repos`. Do not request the `repo` scope.
- No caching of the repo list — every call is live, matching this codebase's existing precedent (`Controller::Plugins::edit_form` already makes uncached GitHub calls per page render).
- No free-text fallback anywhere if the GitHub call fails or returns empty — that would defeat the point of the feature. Show an honest empty/error state instead.
- No pagination beyond GitHub's first 100 results (`per_page=100`) — a known, accepted limitation, not handled in this plan.
- Out of scope entirely: GitLab/Forgejo providers, any of spec §5's levels/review/trust/rating schema, `plugins`/`plugin_versions` schema changes (`slug`, `documentation_url`, `status` state machine), converting any *other* existing endpoint to OpenAPI.
- Design doc: `docs/superpowers/specs/2026-08-07-repo-picker-design.md` — consult it for the "why" behind any decision below.

---

### Task 1: Retain the developer's GitHub token in session

**Files:**
- Modify: `lib/KohaPluginStore.pm` (the `log_in_developer` helper)
- Modify: `lib/KohaPluginStore/Controller/Auth.pm` (the real-flow call site)
- Modify: `t/auth.t`

**Interfaces:**
- Produces: `$c->log_in_developer($developer, $access_token)` — `$access_token` is a new, optional third argument (well, second argument after `$developer` — the helper is called as `$c->log_in_developer($developer, $access_token)`). When present, stored as `$c->session->{github_access_token}`. Later tasks read this key directly.

- [ ] **Step 1: Write a failing test for the new session key**

Append to `t/auth.t`, right after the existing `'GitHub login creates a developer and logs them in'` subtest (find that subtest block and add this immediately after its closing `};`):

```perl
subtest 'GitHub login stores the access token in session for later API calls' => sub {
    $t->app->routes->get('/__test/session_token' => sub {
        my $c = shift;
        return $c->render( json => { token => $c->session->{github_access_token} } );
    });

    $t->get_ok('/__test/session_token')->status_is(200)->json_is( '/token' => 'fake-token' );
};
```

(this registers a route once, added purely to inspect session state from the test — it's added exactly once because this subtest itself only runs once per test-file execution; no route-exists guard is needed)

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/auth.t
```
Expected: FAIL — `/token` is `null`/undef, not `'fake-token'` (the session key doesn't exist yet).

- [ ] **Step 3: Update the `log_in_developer` helper**

In `lib/KohaPluginStore.pm`, change:
```perl
    $self->helper(
        log_in_developer => sub {
            my ( $c, $developer ) = @_;
            $c->session->{developer} = $developer->unblessed;
        }
    );
```
to:
```perl
    $self->helper(
        log_in_developer => sub {
            my ( $c, $developer, $access_token ) = @_;
            $c->session->{developer} = $developer->unblessed;
            $c->session->{github_access_token} = $access_token if $access_token;
        }
    );
```

- [ ] **Step 4: Pass the real token at the real-flow call site**

In `lib/KohaPluginStore/Controller/Auth.pm`, change (inside the `then` callback of `github`, the real-flow branch — leave the `oauth_mock` branch's `$c->log_in_developer($developer);` call completely unchanged, it has no real token):
```perl
            $c->log_in_developer($developer);
            $c->redirect_to('/my-plugins');
        }
    )->catch(
```
to:
```perl
            $c->log_in_developer( $developer, $provider_res->{access_token} );
            $c->redirect_to('/my-plugins');
        }
    )->catch(
```

- [ ] **Step 5: Run `t/auth.t` again to verify it passes**

```bash
prove -l t/auth.t
```
Expected: PASS (all subtests).

- [ ] **Step 6: Run the full suite to confirm nothing else broke**

```bash
prove -l t/
```
Expected: PASS (all files).

- [ ] **Step 7: Commit**

```bash
git add lib/KohaPluginStore.pm lib/KohaPluginStore/Controller/Auth.pm t/auth.t
git commit -m "Retain the developer's GitHub access token in session"
```

---

### Task 2: `KohaPluginStore::GitHub::fetch_public_repos`

**Files:**
- Create: `lib/KohaPluginStore/GitHub.pm`
- Create: `t/github.t`

**Interfaces:**
- Produces: `KohaPluginStore::GitHub::fetch_public_repos($access_token)` → arrayref of `{ full_name => $string, html_url => $string }`, or `[]` if `$access_token` is falsy or the GitHub call fails. **Always call this by its fully-qualified name** (`KohaPluginStore::GitHub::fetch_public_repos(...)`), never via `use KohaPluginStore::GitHub qw(fetch_public_repos);` plus a bareword call — an `Exporter`-style import takes a compile-time snapshot of the sub, which later tasks' tests overriding this sub via typeglob assignment would silently fail to intercept. Fully-qualified calls always resolve the *current* symbol at call time, which is what makes the override work.

- [ ] **Step 1: Write a failing test for the no-token case**

Create `t/github.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::GitHub;

subtest 'no access token returns an empty list without making a request' => sub {
    is_deeply( KohaPluginStore::GitHub::fetch_public_repos(undef), [], 'undef token' );
    is_deeply( KohaPluginStore::GitHub::fetch_public_repos(''), [], 'empty string token' );
};

done_testing();
```

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/github.t
```
Expected: FAIL — `Can't locate KohaPluginStore/GitHub.pm`.

- [ ] **Step 3: Create `KohaPluginStore::GitHub`**

```perl
package KohaPluginStore::GitHub;

use Modern::Perl;
use Mojo::UserAgent;

sub fetch_public_repos {
    my ($access_token) = @_;

    return [] unless $access_token;

    my $tx = Mojo::UserAgent->new->get(
        'https://api.github.com/user/repos?visibility=public&sort=updated&per_page=100' => {
            Accept        => 'application/vnd.github+json',
            Authorization => 'Bearer ' . $access_token,
        }
    );

    return [] unless $tx->result->code == 200;

    my $repos = $tx->result->json;
    return [ map { { full_name => $_->{full_name}, html_url => $_->{html_url} } } @$repos ];
}

1;
```

- [ ] **Step 4: Run `t/github.t` again to verify it passes**

```bash
prove -l t/github.t
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/GitHub.pm t/github.t
git commit -m "Add KohaPluginStore::GitHub::fetch_public_repos"
```

---

### Task 3: `GET /api/v1/developer/repos`

**Files:**
- Modify: `lib/KohaPluginStore/OpenAPI/spec.yaml`
- Modify: `lib/KohaPluginStore.pm` (OpenAPI plugin registration)
- Modify: `lib/KohaPluginStore/Controller/Api.pm`
- Create: `t/api_developer_repos.t`

**Interfaces:**
- Consumes: `KohaPluginStore::GitHub::fetch_public_repos` (Task 2), `$c->session->{github_access_token}` / `$c->session->{developer}` (Task 1 and existing login work).
- Produces: `GET /api/v1/developer/repos` — 401 (auto-generated by the OpenAPI Security plugin) if not logged in, 200 with `{ "repos": [ { "full_name": ..., "html_url": ... }, ... ] }` otherwise (empty array if the developer has no `github_access_token`, e.g. logged in via `oauth_mock`).

- [ ] **Step 1: Write failing tests**

Create `t/api_developer_repos.t`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

subtest 'anonymous request is rejected' => sub {
    $t->get_ok('/api/v1/developer/repos')->status_is(401);
};

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_public_repos = sub {
        return [ { full_name => 'octocat/Hello-World', html_url => 'https://github.com/octocat/Hello-World' } ];
    };
}

subtest 'logged-in developer gets their repo list' => sub {
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    $t->get_ok('/api/v1/developer/repos')
      ->status_is(200)
      ->json_is( '/repos/0/full_name' => 'octocat/Hello-World' )
      ->json_is( '/repos/0/html_url'  => 'https://github.com/octocat/Hello-World' );
};

done_testing();
```

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/api_developer_repos.t
```
Expected: FAIL — 404 (no such path defined yet), not 401.

- [ ] **Step 3: Add the path to `spec.yaml`**

The full file becomes:

```yaml
openapi: 3.0.1
info:
  title: Koha Plugin Store API
  version: "1"
x-mojo-controller: KohaPluginStore::Controller::Api
components:
  securitySchemes:
    session_auth:
      type: apiKey
      in: cookie
      name: mojolicious
paths:
  /ping:
    get:
      operationId: ping
      x-mojo-to: api#ping
      responses:
        '200':
          description: Service is up
          content:
            application/json:
              schema:
                type: object
                properties:
                  status:
                    type: string
                required:
                  - status
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
                required:
                  - repos
                properties:
                  repos:
                    type: array
                    items:
                      type: object
                      required:
                        - full_name
                        - html_url
                      properties:
                        full_name:
                          type: string
                        html_url:
                          type: string
        '401':
          description: Not logged in
          content:
            application/json:
              schema:
                type: object
```

- [ ] **Step 4: Register the security callback in `startup()`**

In `lib/KohaPluginStore.pm`, change:
```perl
    $self->plugin( 'OpenAPI', {
        url   => $self->home->child(qw(lib KohaPluginStore OpenAPI spec.yaml)),
        route => $self->routes->any('/api/v1'),
    } );
```
to:
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

- [ ] **Step 5: Add the controller action**

In `lib/KohaPluginStore/Controller/Api.pm`, change:
```perl
package KohaPluginStore::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub ping ($c) {
    return $c->render( openapi => { status => 'ok' } );
}

1;
```
to:
```perl
package KohaPluginStore::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::GitHub;

sub ping ($c) {
    return $c->render( openapi => { status => 'ok' } );
}

sub developer_repos ($c) {
    my $repos = KohaPluginStore::GitHub::fetch_public_repos( $c->session->{github_access_token} );
    return $c->render( openapi => { repos => $repos } );
}

1;
```

- [ ] **Step 6: Run `t/api_developer_repos.t` again to verify it passes**

```bash
prove -l t/api_developer_repos.t
```
Expected: PASS.

- [ ] **Step 7: Run the full suite**

```bash
prove -l t/
```
Expected: PASS — including `t/openapi_ping.t`, confirming the existing `/ping` operation is unaffected by adding `security` to a *different* operation (per the plugin's own documented behavior, only operations that declare `security` are gated).

- [ ] **Step 8: Commit**

```bash
git add lib/KohaPluginStore/OpenAPI/spec.yaml lib/KohaPluginStore.pm lib/KohaPluginStore/Controller/Api.pm t/api_developer_repos.t
git commit -m "Add GET /api/v1/developer/repos, gated by OpenAPI's own security mechanism"
```

---

### Task 4: Submission form dropdown

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (`add_form`, plus the `use` statements at the top)
- Modify: `templates/new-plugin.html.ep`
- Create: `t/plugins_add_form.t`

**Interfaces:**
- Consumes: `KohaPluginStore::GitHub::fetch_public_repos` (Task 2).
- Produces: `add_form` stashes `repos` (arrayref, same shape as Task 2/3) when rendering the `new-plugin` template.

- [ ] **Step 1: Write failing tests**

Create `t/plugins_add_form.t`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

$t->app->config->{oauth_mock} = 1;
$t->get_ok('/auth/github');
$t->app->config->{oauth_mock} = 0;

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_public_repos = sub {
        return [ { full_name => 'octocat/Hello-World', html_url => 'https://github.com/octocat/Hello-World' } ];
    };
}

subtest 'shows a repo dropdown populated from the developer\'s GitHub repos' => sub {
    $t->get_ok('/new-plugin')
      ->status_is(200)
      ->element_exists('select[name="plugin_repo"]')
      ->element_exists('option[value="https://github.com/octocat/Hello-World"]');
};

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_public_repos = sub { return []; };
}

subtest 'shows a message when the developer has no public repos' => sub {
    $t->get_ok('/new-plugin')
      ->status_is(200)
      ->element_exists_not('select[name="plugin_repo"]')
      ->text_like( 'body' => qr/No public GitHub repositories found/ );
};

done_testing();
```

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/plugins_add_form.t
```
Expected: FAIL — no `<select name="plugin_repo">` exists yet (the form still has the free-text input).

- [ ] **Step 3: Update `add_form`**

In `lib/KohaPluginStore/Controller/Plugins.pm`, add `use KohaPluginStore::GitHub;` alongside the existing `use` statements at the top of the file, then change:
```perl
sub add_form {
    my $c = shift;

    my $template = $c->session->{developer} ? 'new-plugin' : 'unauthorized';
    $c->render($template);
}
```
to:
```perl
sub add_form {
    my $c = shift;

    my $template = $c->session->{developer} ? 'new-plugin' : 'unauthorized';
    if ( $template eq 'new-plugin' ) {
        my $repos = KohaPluginStore::GitHub::fetch_public_repos( $c->session->{github_access_token} );
        $c->stash( repos => $repos );
    }
    $c->render($template);
}
```

- [ ] **Step 4: Update the template**

In `templates/new-plugin.html.ep`, change:
```eplite
  <div class="mb-3">
    <input required type="url" class="form-control" name="plugin_repo" id="plugin_repo" placeholder="Plugin repository" aria-describedby="repoHelp">
    <div id="repoHelp" class="form-text">The <i class='bx bxl-github' ></i> github repo URL. Example: <a target="_blank" href="https://github.com/bywatersolutions/koha-plugin-coverflow">https://github.com/bywatersolutions/koha-plugin-coverflow</a></div>
  </div>
```
to:
```eplite
  <div class="mb-3">
    % if (@$repos) {
    <select required class="form-select" name="plugin_repo" id="plugin_repo" aria-describedby="repoHelp">
      <option value="" disabled selected>Choose a repository&hellip;</option>
      % for my $repo (@$repos) {
      <option value="<%= $repo->{html_url} %>"><%= $repo->{full_name} %></option>
      % }
    </select>
    <div id="repoHelp" class="form-text">Only your public <i class='bx bxl-github'></i> GitHub repositories are listed here.</div>
    % } else {
    <p class="text-danger">No public GitHub repositories found for your account. Make sure your plugin's repository is public, then refresh this page.</p>
    % }
  </div>
```

- [ ] **Step 5: Run `t/plugins_add_form.t` again to verify it passes**

```bash
prove -l t/plugins_add_form.t
```
Expected: PASS.

- [ ] **Step 6: Run the full suite**

```bash
prove -l t/
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm templates/new-plugin.html.ep t/plugins_add_form.t
git commit -m "Replace free-text repo URL with a picker from the developer's GitHub repos"
```

---

### Task 5: Server-side enforcement in `new_plugin`

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (`new_plugin`)
- Create: `t/plugins_new_plugin_ownership.t`

**Interfaces:**
- Consumes: `KohaPluginStore::GitHub::fetch_public_repos` (Task 2), `_exit_with_error_message` (existing private method, renders `new-plugin-step2` with an error list — unchanged, just reused).

- [ ] **Step 1: Write a failing test**

Create `t/plugins_new_plugin_ownership.t`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

$t->app->config->{oauth_mock} = 1;
$t->get_ok('/auth/github');
$t->app->config->{oauth_mock} = 0;

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_public_repos = sub {
        return [ { full_name => 'octocat/Hello-World', html_url => 'https://github.com/octocat/Hello-World' } ];
    };
}

subtest 'rejects a repo not in the developer\'s own list, without calling GitHub for release info' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Controller::Plugins::_get_latest_release_from_github = sub {
        die 'should not be called for an unowned repo';
    };

    $t->post_ok( '/new-plugin' => form => { plugin_repo => 'https://github.com/someone-else/not-mine' } )
      ->status_is(200)
      ->text_like( 'body' => qr/not in the list of your public GitHub repositories/ );
};

done_testing();
```

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/plugins_new_plugin_ownership.t
```
Expected: FAIL — the stubbed `_get_latest_release_from_github` dies (uncaught), because `new_plugin` currently calls it unconditionally with no ownership check first.

- [ ] **Step 3: Add the ownership check**

In `lib/KohaPluginStore/Controller/Plugins.pm`, change the start of `new_plugin`:
```perl
sub new_plugin ($c) {
    my $plugin_repo = $c->param('plugin_repo');
    my $config      = $c->app->plugin('Config');
    my @errors;

    my $result = $c->_get_latest_release_from_github($plugin_repo);
```
to:
```perl
sub new_plugin ($c) {
    my $plugin_repo = $c->param('plugin_repo');
    my $config      = $c->app->plugin('Config');
    my @errors;

    my $developer_repos = KohaPluginStore::GitHub::fetch_public_repos( $c->session->{github_access_token} );
    my $repo_is_owned   = grep { $_->{html_url} eq $plugin_repo } @$developer_repos;
    return $c->_exit_with_error_message(
        'That repository is not in the list of your public GitHub repositories. Please pick one from the dropdown.'
    ) unless $repo_is_owned;

    my $result = $c->_get_latest_release_from_github($plugin_repo);
```

(leave everything else in `new_plugin` unchanged)

- [ ] **Step 4: Run `t/plugins_new_plugin_ownership.t` again to verify it passes**

```bash
prove -l t/plugins_new_plugin_ownership.t
```
Expected: PASS.

- [ ] **Step 5: Run the full suite**

```bash
prove -l t/
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm t/plugins_new_plugin_ownership.t
git commit -m "Reject plugin submissions for repos outside the developer's own GitHub list"
```

---

### Task 6: Update docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Interfaces:**
- None — documentation only.

- [ ] **Step 1: Update `CLAUDE.md`**

In the "Plugin submission workflow (`Controller::Plugins`)" section, add a note before point 1 of the numbered list: plugin submission now picks from `GET /api/v1/developer/repos` (the developer's own public GitHub repos, fetched via `KohaPluginStore::GitHub::fetch_public_repos` using the access token stored in session at login) rather than accepting an arbitrary URL — `new_plugin` re-validates the submitted repo against that same list server-side, since the dropdown alone doesn't stop a hand-crafted request.

In the "Data layer" or "Architecture" section (wherever `Controller::Auth`/OAuth is currently described), add one line: the developer's GitHub access token is now kept in `session->{github_access_token}` after login (previously discarded), specifically so later requests can call GitHub's API as the developer.

- [ ] **Step 2: Update `README.md`**

In the "Notes" section, add: submitting a plugin now requires the developer to have at least one public GitHub repository — the submission form picks from a list of the developer's own public repos rather than accepting a free-text URL.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "Document the repo picker"
```
