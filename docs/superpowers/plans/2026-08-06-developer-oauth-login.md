# Developer OAuth Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the app's username/password developer login with GitHub OAuth (via `Mojolicious::Plugin::OAuth2`), cutting over the identity model from a `users` table to a `developers` table, and fixing a live ownership gap in release submission along the way.

**Architecture:** A new `developers` table (keyed on GitHub identity) replaces `users`; `Model::Developer` replaces `Model::User`. `Mojolicious::Plugin::OAuth2`, configured from a small `oauth_providers` list in `koha_plugin_store.conf`, owns the redirect/CSRF/token-exchange mechanics; a new `Controller::Auth` action fetches the GitHub profile with the resulting token and finds-or-creates the `developers` row. Every other controller/template touchpoint that referenced `session->{user}` or `plugin->user_id` moves to `session->{developer}` / `plugin->developer_id`.

**Tech Stack:** Mojolicious, `Mojolicious::Plugin::OAuth2`, `Mojo::Pg`, `Test::Mojo`.

## Global Constraints

- This is a full cutover, not a parallel option: password login/register is removed entirely, not kept alongside OAuth.
- No dev-login bypass — local/Docker dev registers a real GitHub OAuth App, same pattern as the existing `github_user_access_token` config.
- Request no OAuth scopes beyond GitHub's default (public profile only) — `developers` has no email column.
- Out of scope: GitLab/Forgejo providers, the `GET /api/v1/developer/repos` repo-picker, and any of spec §5's levels/review/trust/rating tables. Don't build toward these speculatively.
- `plugins.developer_id` is set once at plugin creation and never updated afterward — no ownership-transfer or multi-maintainer history in this plan.
- Design doc: `docs/superpowers/specs/2026-08-06-developer-oauth-login-design.md` — consult it for the "why" behind any decision below.

---

### Task 1: Schema migration — `developers` table, `plugins.developer_id`, drop `users`

**Files:**
- Modify: `lib/KohaPluginStore/Command/migrate.pm` (append to the `__DATA__` migrations section)
- Modify: `t/lib/TestDB.pm:17-19` (`reset_db`'s `TRUNCATE` list)

**Interfaces:**
- Produces: `developers` table (`id, oauth_provider_key, provider_user_id, username, avatar_url, created_at`, unique on `(oauth_provider_key, provider_user_id)`); `plugins.developer_id` (replaces `plugins.user_id`). Every later task depends on this schema existing.

- [ ] **Step 1: Append migration 2 to `migrate.pm`'s `__DATA__` section**

Add immediately after the existing `-- 1 down` block (do not touch migration 1):

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

- [ ] **Step 2: Update `t/lib/TestDB.pm`'s truncate list**

Change:
```perl
sub reset_db {
    $PG->db->query(
        'TRUNCATE plugin_versions, plugins, users RESTART IDENTITY CASCADE'
    );
}
```
to:
```perl
sub reset_db {
    $PG->db->query(
        'TRUNCATE plugin_versions, plugins, developers RESTART IDENTITY CASCADE'
    );
}
```

- [ ] **Step 3: Run the migration against the test Postgres and verify the schema**

```bash
docker compose up -d postgres
KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@127.0.0.1:55432/koha_plugin_store' \
  perl -Ilib -MKohaPluginStore -e '
    my $app = KohaPluginStore->new;
    $app->config->{pg_dsn} = "postgresql://koha_plugin_store:koha_plugin_store\@127.0.0.1:55432/koha_plugin_store";
    $app->pg->migrations->from_data("KohaPluginStore::Command::migrate")->migrate;
    my $cols = $app->pg->db->query("select column_name from information_schema.columns where table_name = ?", "developers")->arrays;
    print "developers columns: ", join(",", map { $_->[0] } @$cols), "\n";
    my $pcols = $app->pg->db->query("select column_name from information_schema.columns where table_name = ?", "plugins")->arrays;
    print "plugins columns: ", join(",", map { $_->[0] } @$pcols), "\n";
  '
```

Expected: `developers columns:` lists `id,oauth_provider_key,provider_user_id,username,avatar_url,created_at` (order may vary); `plugins columns:` includes `developer_id` and does not include `user_id`; no `users` table.

- [ ] **Step 4: Commit**

```bash
git add lib/KohaPluginStore/Command/migrate.pm t/lib/TestDB.pm
git commit -m "Add developers table, plugins.developer_id; drop users table"
```

---

### Task 2: Model layer — `Model::Developer`, `Model::Base` gains `update`, `Model::Plugin` column rename

**Files:**
- Create: `lib/KohaPluginStore/Model/Developer.pm`
- Create: `t/model_developer.t`
- Modify: `lib/KohaPluginStore/Model/Base.pm` (add `update` method)
- Modify: `t/model_base.t` (new subtest for `update`; fix `TestPlugin`'s `_columns` fixture)
- Modify: `lib/KohaPluginStore/Model/Plugin.pm:14` (`_columns`: `user_id` → `developer_id`)
- Modify: `lib/KohaPluginStore/Controller/Users.pm` (`Model::User` → `Model::Developer`)
- Delete: `lib/KohaPluginStore/Model/User.pm`
- Delete: `t/model_user.t`
- Modify: `cpanfile` (remove `Passwords` — its only consumer, `Model::User`, is deleted in this task)

**Interfaces:**
- Consumes: `Model::Base`'s `has 'pg'`, `has 'data'`, `create`/`find`/`search`/`_new_from_row` (unchanged from pg-injection work).
- Produces: `KohaPluginStore::Model::Developer->new( pg => $pg )->find_or_create_from_oauth({ oauth_provider_key, provider_user_id, username, avatar_url })` → a `Model::Developer` instance. `KohaPluginStore::Model::Base::update($self, \%attrs)` → `$self` (mutates the row and the in-memory object). Task 4 (Controller::Auth) calls `find_or_create_from_oauth` directly.

- [ ] **Step 1: Add a failing test for `Model::Base`'s `update`**

Append to `t/model_base.t`, before `done_testing();`:

```perl
subtest 'update modifies the row and the in-memory object' => sub {
    my $plugin = TestPlugin->new( pg => test_pg() )->create( { name => 'Updatable', description => 'Before' } );
    my $result = $plugin->update( { description => 'After' } );
    is( $result, $plugin, 'update returns the same object' );
    is( $plugin->description, 'After', 'in-memory value updated' );
    my $reloaded = TestPlugin->new( pg => test_pg() )->find( { name => 'Updatable' } );
    is( $reloaded->description, 'After', 'persisted value updated' );
};
```

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/model_base.t
```
Expected: FAIL — `Can't locate object method "update"`.

- [ ] **Step 3: Add `update` to `Model::Base`**

In `lib/KohaPluginStore/Model/Base.pm`, add after `search`:

```perl
sub update {
    my ( $self, $attrs ) = @_;

    $self->pg->db->update( $self->_table, $attrs, { id => $self->id } );
    $self->data->{$_} = $attrs->{$_} for keys %$attrs;

    return $self;
}
```

- [ ] **Step 4: Fix `t/model_base.t`'s `TestPlugin` fixture**

The `plugins` table no longer has a `user_id` column (Task 1). Change:
```perl
sub _columns { return [qw(id repo_url name class_name description author thumbnail user_id timestamp)] }
```
to:
```perl
sub _columns { return [qw(id repo_url name class_name description author thumbnail developer_id timestamp)] }
```

- [ ] **Step 5: Run `t/model_base.t` again to verify it passes**

```bash
prove -l t/model_base.t
```
Expected: PASS (all subtests, including the new one).

- [ ] **Step 6: Write a failing test for `Model::Developer`**

Create `t/model_developer.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Developer;

reset_db();

subtest 'find_or_create_from_oauth creates on first login' => sub {
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find_or_create_from_oauth(
        {
            oauth_provider_key => 'github',
            provider_user_id   => '12345',
            username            => 'octocat',
            avatar_url          => 'https://example.com/octocat.png',
        }
    );
    ok( $developer->id, 'id was assigned' );
    is( $developer->username, 'octocat', 'username set' );
};

subtest 'find_or_create_from_oauth finds and refreshes an existing developer' => sub {
    my $first = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find_or_create_from_oauth(
        {
            oauth_provider_key => 'github',
            provider_user_id   => '99999',
            username            => 'oldname',
            avatar_url          => 'https://example.com/old.png',
        }
    );
    my $second = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find_or_create_from_oauth(
        {
            oauth_provider_key => 'github',
            provider_user_id   => '99999',
            username            => 'newname',
            avatar_url          => 'https://example.com/new.png',
        }
    );
    is( $second->id, $first->id, 'same developer row, not a new one' );
    is( $second->username, 'newname', 'username refreshed' );

    my $reloaded = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find( { id => $first->id } );
    is( $reloaded->username, 'newname', 'refresh was persisted' );
};

done_testing();
```

- [ ] **Step 7: Run it to verify it fails**

```bash
prove -l t/model_developer.t
```
Expected: FAIL — `Can't locate KohaPluginStore/Model/Developer.pm`.

- [ ] **Step 8: Create `Model::Developer`**

```perl
package KohaPluginStore::Model::Developer;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

sub _table {
    return 'developers';
}

sub _columns {
    return [qw(id oauth_provider_key provider_user_id username avatar_url created_at)];
}

sub find_or_create_from_oauth {
    my ( $self, $attrs ) = @_;

    my $developer = $self->find(
        {
            oauth_provider_key => $attrs->{oauth_provider_key},
            provider_user_id   => $attrs->{provider_user_id},
        }
    );

    return $developer->update(
        { username => $attrs->{username}, avatar_url => $attrs->{avatar_url} }
    ) if $developer;

    return $self->create($attrs);
}

1;
```

- [ ] **Step 9: Run `t/model_developer.t` to verify it passes**

```bash
prove -l t/model_developer.t
```
Expected: PASS.

- [ ] **Step 10: Rename `Model::Plugin`'s `user_id` column to `developer_id`**

In `lib/KohaPluginStore/Model/Plugin.pm`, change:
```perl
sub _columns {
    return [qw(id repo_url name class_name description author thumbnail user_id timestamp)];
}
```
to:
```perl
sub _columns {
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp)];
}
```

- [ ] **Step 11: Update `Controller::Users.pm` to use `Model::Developer`**

In `lib/KohaPluginStore/Controller/Users.pm`, change:
```perl
use KohaPluginStore::Model::User;

sub index {
    my $c = shift;

    my @users = KohaPluginStore::Model::User->new( pg => $c->pg )->search();
```
to:
```perl
use KohaPluginStore::Model::Developer;

sub index {
    my $c = shift;

    my @users = KohaPluginStore::Model::Developer->new( pg => $c->pg )->search();
```
(Leave `$c->stash( users => \@users )` and the template name unchanged — `templates/users/index.html.ep` and `templates/partial/table/users.html.ep` only read `->id`/`->username`, which `Model::Developer` also provides.)

- [ ] **Step 12: Delete `Model::User` and its test**

```bash
git rm lib/KohaPluginStore/Model/User.pm t/model_user.t
```

- [ ] **Step 13: Remove the now-unused `Passwords` dependency**

In `cpanfile`, remove the line `requires 'Passwords';` (its only consumer was `Model::User`, just deleted).

- [ ] **Step 14: Run the full suite**

```bash
prove -l t/
```
Expected: `t/model_user.t` is gone; `t/api_plugins.t` and `t/site.t` will fail at this point (they still reference `Model::User`/`user_id`/password login) — that's expected, Tasks 4-7 fix them. Confirm `t/model_base.t`, `t/model_developer.t`, and `t/model_plugin.t` pass.

- [ ] **Step 15: Commit**

```bash
git add lib/KohaPluginStore/Model/Developer.pm lib/KohaPluginStore/Model/Base.pm \
        lib/KohaPluginStore/Model/Plugin.pm lib/KohaPluginStore/Controller/Users.pm \
        t/model_developer.t t/model_base.t cpanfile
git rm lib/KohaPluginStore/Model/User.pm t/model_user.t
git commit -m "Add Model::Developer, Model::Base::update; rename Plugin's user_id to developer_id"
```

---

### Task 3: Wire up `Mojolicious::Plugin::OAuth2`

**Files:**
- Modify: `cpanfile` (add `Mojolicious::Plugin::OAuth2`)
- Modify: `lib/KohaPluginStore.pm` (register the plugin from config-driven `oauth_providers`)
- Modify: `koha_plugin_store.conf.example`, `koha_plugin_store.conf.docker.example` (add an `oauth_providers` example block)

**Interfaces:**
- Consumes: `$self->config->{oauth_providers}` — an arrayref of `{ key, kind, display_name, client_id, client_secret }` hashes (see design doc §"Provider configuration").
- Produces: `$c->oauth2` helper (from the plugin itself) usable by Task 4's `Controller::Auth`, registered for provider key `github`.

- [ ] **Step 1: Add the dependency**

In `cpanfile`, add:
```perl
requires 'Mojolicious::Plugin::OAuth2';
```

- [ ] **Step 2: Install it**

```bash
cpanm --installdeps .
```

Confirmed against `Mojolicious::Plugin::OAuth2` v2.02's own POD (`register`
section): `$app->plugin(OAuth2 => \%provider_config)` accepts a flat hash of
`provider_name => { key => ..., secret => ... }` directly — `github` is one
of its bundled provider names, recognised automatically. Step 3 uses this
flat form.

- [ ] **Step 3: Register the plugin in `startup()`**

In `lib/KohaPluginStore.pm`, add near the top (after `use Mojo::Pg;`):
```perl
use Mojolicious::Plugin::OAuth2;
```

In `startup()`, after `$self->plugin('Config');`, add:
```perl
my %oauth2_providers;
for my $provider ( @{ $self->config->{oauth_providers} || [] } ) {
    if ( $provider->{kind} eq 'github' ) {
        $oauth2_providers{ $provider->{key} } = {
            key    => $provider->{client_id},
            secret => $provider->{client_secret},
        };
    }
}
$self->plugin( OAuth2 => \%oauth2_providers );
```

- [ ] **Step 4: Document the config in both conf examples**

In `koha_plugin_store.conf.example`, add before the closing `};`:
```perl
  # OAuth providers for developer login. 'github' is a built-in provider name
  # recognised by Mojolicious::Plugin::OAuth2 -- register an OAuth App at
  # https://github.com/settings/developers to get a client_id/client_secret.
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
Add the same block to `koha_plugin_store.conf.docker.example`.

- [ ] **Step 5: Verify the app still boots with no `oauth_providers` configured**

```bash
prove -l t/basic.t
```
Expected: PASS — `t/basic.t` doesn't set `oauth_providers`, confirming the `|| []` default means an app with no OAuth config at all still boots (existing behaviour must not break for tests that don't care about auth).

- [ ] **Step 6: Commit**

```bash
git add cpanfile lib/KohaPluginStore.pm koha_plugin_store.conf.example koha_plugin_store.conf.docker.example
git commit -m "Register Mojolicious::Plugin::OAuth2 from config-driven oauth_providers"
```

---

### Task 4: `Controller::Auth`, app helpers, and routes

**Files:**
- Create: `lib/KohaPluginStore/Controller/Auth.pm`
- Create: `t/auth.t`
- Modify: `lib/KohaPluginStore.pm` (routes, `logged_in_user` helper, new `log_in_developer` helper, `user_authenticated` condition)

**Interfaces:**
- Consumes: `Model::Developer->find_or_create_from_oauth` (Task 2), `$c->oauth2->get_token_p($provider)` (Task 3).
- Produces: `GET /auth/github` route. `$c->log_in_developer($developer)` helper (sets `$c->session->{developer}`), used by `Controller::Auth`. `$c->logged_in_user` helper now returns a `Model::Developer` (same external shape as before: `->id`, `->username`). `KohaPluginStore::Controller::Auth::_get_oauth_token_p` and `::_fetch_github_profile` — ordinary package subs (not Mojolicious helpers), deliberately factored out so later tasks' tests can override them by simple typeglob assignment instead of mocking HTTP or Mojolicious::Plugin::OAuth2's internals.

- [ ] **Step 1: Write `Controller::Auth`**

`_get_oauth_token_p` and `_fetch_github_profile` are both plain package
subs (not routed actions, not Mojolicious helpers) specifically so tests can
override them with a simple typeglob assignment — see Step 4.

```perl
package KohaPluginStore::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::Developer;

sub github ($c) {
    $c->_get_oauth_token_p('github')->then(
        sub {
            my $provider_res = shift;
            return unless $provider_res && $provider_res->{access_token};

            my $profile = $c->_fetch_github_profile( $provider_res->{access_token} );
            return $c->render( text => 'Could not fetch GitHub profile', status => 502 )
                unless $profile;

            my $developer = KohaPluginStore::Model::Developer->new( pg => $c->pg )->find_or_create_from_oauth(
                {
                    oauth_provider_key => 'github',
                    provider_user_id   => $profile->{id},
                    username           => $profile->{login},
                    avatar_url         => $profile->{avatar_url},
                }
            );

            $c->log_in_developer($developer);
            $c->redirect_to('/my-plugins');
        }
    )->catch(
        sub {
            my $err = shift;
            $c->app->log->error("GitHub OAuth failed: $err");
            $c->render( text => 'GitHub login failed', status => 502 );
        }
    );
}

sub _get_oauth_token_p {
    my ( $c, $provider ) = @_;
    return $c->oauth2->get_token_p($provider);
}

sub _fetch_github_profile {
    my ( $c, $access_token ) = @_;

    my $tx = Mojo::UserAgent->new->get(
        'https://api.github.com/user' => {
            Accept        => 'application/vnd.github+json',
            Authorization => 'Bearer ' . $access_token,
        }
    );

    return unless $tx->result->code == 200;

    return $tx->result->json;
}

1;
```

- [ ] **Step 2: Add the `log_in_developer` helper and update `logged_in_user`, in `lib/KohaPluginStore.pm`**

Change:
```perl
use KohaPluginStore::Model::User;
use KohaPluginStore::Model::Plugin;
```
to:
```perl
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
```

Change the `logged_in_user` helper:
```perl
    $self->helper(
        logged_in_user => sub {
            my ( $c, $user ) = @_;
            $user ||= $c->stash->{user} || $c->session->{user};
            return unless $user;
            return KohaPluginStore::Model::User->new( pg => $c->pg )->find( { username => $user->{username} } )
              || undef;
        }
    );
```
to:
```perl
    $self->helper(
        logged_in_user => sub {
            my ( $c, $developer ) = @_;
            $developer ||= $c->stash->{developer} || $c->session->{developer};
            return unless $developer;
            return KohaPluginStore::Model::Developer->new( pg => $c->pg )->find( { id => $developer->{id} } )
              || undef;
        }
    );

    $self->helper(
        log_in_developer => sub {
            my ( $c, $developer ) = @_;
            $c->session->{developer} = $developer->unblessed;
        }
    );
```

Change the `user_authenticated` condition in `_add_routes_authorization`:
```perl
        if ( defined(  $c->session->{user}->{id} ) ) {
```
to:
```perl
        if ( defined(  $c->session->{developer}->{id} ) ) {
```

- [ ] **Step 3: Update routes**

Remove:
```perl
    $r->post('/login')->to('site#login');
    $r->get('/register')->to( template => 'register' );
    $r->post('/register')->to('site#register');
```

Change:
```perl
    $r->get('/login')->to( template => 'login' );
```
to (unchanged URL, still a plain template render — the template itself changes in Task 5):
```perl
    $r->get('/login')->to( template => 'login' );
```
(no change needed to this line — leave as-is)

Add, near the other routes:
```perl
    $r->get('/auth/github')->to('auth#github');
```

- [ ] **Step 4: Write `t/auth.t`, overriding the two GitHub-specific package subs**

`_get_oauth_token_p` and `_fetch_github_profile` are ordinary package subs
(Step 1), so overriding them with a typeglob assignment is a standard,
reliable Perl technique — no HTTP mocking and no dependency on
`Mojolicious::Plugin::OAuth2`'s internals:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojo::Promise;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Controller::Auth::_get_oauth_token_p = sub {
        return Mojo::Promise->resolve( { access_token => 'fake-token' } );
    };
    *KohaPluginStore::Controller::Auth::_fetch_github_profile = sub {
        return { id => '4242', login => 'octocat', avatar_url => 'https://example.com/o.png' };
    };
}

subtest 'GitHub login creates a developer and logs them in' => sub {
    $t->get_ok('/auth/github')->status_is(302)->header_is( Location => '/my-plugins' );
};

subtest 'my-plugins requires login' => sub {
    $t->get_ok('/logout')->status_is(302);
    $t->get_ok('/my-plugins')->status_is(404); # existing #TODO in the app: this should be 401
};

done_testing();
```

- [ ] **Step 5: Run `t/auth.t`**

```bash
prove -l t/auth.t
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore/Controller/Auth.pm lib/KohaPluginStore.pm t/auth.t
git commit -m "Add GitHub OAuth login flow (Controller::Auth, log_in_developer helper)"
```

---

### Task 5: Cut over remaining session/ownership call sites and templates

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Site.pm` (remove `login`, `register`, `_log_in_user`)
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm:18,21,28,43,213` (`session->{user}` → `session->{developer}`; `user_id` → `developer_id`)
- Modify: `templates/login.html.ep` (GitHub link instead of a password form)
- Delete: `templates/register.html.ep`
- Modify: `templates/partial/auth_menu.html.ep` (remove the "Register" link)
- Modify: `templates/partial/table/plugins.html.ep` (`user_id` → `developer_id`)

**Interfaces:**
- Consumes: `$c->session->{developer}`, `Model::Plugin`'s `developer_id` column (both from earlier tasks).

- [ ] **Step 1: Strip `Controller::Site.pm` down to `index`/`logout`**

Replace the whole file with:
```perl
package KohaPluginStore::Controller::Site;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;

sub index {
    my $c = shift;

    my @developers = KohaPluginStore::Model::Developer->new( pg => $c->pg )->search;
    my @plugins    = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search;
    $c->stash( plugins => \@plugins );
    $c->stash( users   => \@developers );
    $c->render;
}

sub logout {
    my $c = shift;
    $c->session( expires => 1 );
    $c->redirect_to('/');
}

1;
```
(`index` keeps stashing under the `users` key — `templates/site/index.html.ep` and `templates/partial/table/users.html.ep` read that stash key and only use `->id`/`->username`, unaffected by the underlying model change.)

- [ ] **Step 2: Update `Controller::Plugins.pm`'s session/ownership references**

Change (line 18):
```perl
    my @plugins = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search( { user_id => $c->session->{user}->{id} } );
```
to:
```perl
    my @plugins = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search( { developer_id => $c->session->{developer}->{id} } );
```

Change (line 21):
```perl
    my $template = $c->session->{user} ? 'my-plugins' : 'unauthorized';
```
to:
```perl
    my $template = $c->session->{developer} ? 'my-plugins' : 'unauthorized';
```

Change (line 28):
```perl
    my $template = $c->session->{user} ? 'new-plugin' : 'unauthorized';
```
to:
```perl
    my $template = $c->session->{developer} ? 'new-plugin' : 'unauthorized';
```

Change (line 43):
```perl
    return $c->render( text => 'Unauthorized',     status => 401 ) unless $c->session->{user}->{id} == $plugin->user_id;
```
to:
```perl
    return $c->render( text => 'Unauthorized',     status => 401 ) unless $c->session->{developer}->{id} == $plugin->developer_id;
```

Change (line 213):
```perl
            user_id     => $c->session->{user}->{id}
```
to:
```perl
            developer_id => $c->session->{developer}->{id}
```

- [ ] **Step 3: Replace `templates/login.html.ep`**

```eplite
% title 'Login';
% layout 'default';

% content_for 'sidebar' => begin
  %= include 'partial/side_menu'
% end

<h2><%= title %></h2>

<p>
  %= link_to '/auth/github' => (class => 'btn btn-dark') => begin
    <i class='bx bxl-github'></i> Log in with GitHub
  % end
</p>
```

- [ ] **Step 4: Delete `templates/register.html.ep`**

```bash
git rm templates/register.html.ep
```

- [ ] **Step 5: Remove the "Register" link from `templates/partial/auth_menu.html.ep`**

Change:
```eplite
  % } else{
    %= link_to '/login' => (class => 'list-group-item list-group-item-action ' . (current_route eq 'login' ? 'active' : '' )) => begin
      <i class='bx bx-log-in'></i> Log In
    % end
    %= link_to '/register' => (class => 'list-group-item list-group-item-action ' . (current_route eq 'register' ? 'active' : '' )) => begin
      <i class='bx bx-user-plus'></i> Register
    % end
  % }
```
to:
```eplite
  % } else{
    %= link_to '/login' => (class => 'list-group-item list-group-item-action ' . (current_route eq 'login' ? 'active' : '' )) => begin
      <i class='bx bx-log-in'></i> Log In
    % end
  % }
```

- [ ] **Step 6: Update `templates/partial/table/plugins.html.ep`**

Change:
```eplite
      <th>User ID</th>
```
to:
```eplite
      <th>Developer ID</th>
```
Change:
```eplite
      %= t td => $plugin->user_id
```
to:
```eplite
      %= t td => $plugin->developer_id
```
Change:
```eplite
      % if (logged_in_user && logged_in_user->id eq $plugin->user_id){
```
to:
```eplite
      % if (logged_in_user && logged_in_user->id eq $plugin->developer_id){
```

- [ ] **Step 7: Commit**

```bash
git add lib/KohaPluginStore/Controller/Site.pm lib/KohaPluginStore/Controller/Plugins.pm \
        templates/login.html.ep templates/partial/auth_menu.html.ep templates/partial/table/plugins.html.ep
git rm templates/register.html.ep
git commit -m "Cut over remaining session/ownership call sites from user_id to developer_id"
```

(Don't run the full suite yet — `t/site.t` and `t/api_plugins.t` still reference the old password flow and `Model::User`; Task 7 fixes them. `prove -l t/model_base.t t/model_developer.t t/model_plugin.t t/auth.t` should all still pass after this task.)

---

### Task 6: Fix the `Releases.pm` ownership gap

**Files:**
- Modify: `lib/KohaPluginStore.pm` (gate the `/new-release` route)
- Modify: `lib/KohaPluginStore/Controller/Releases.pm` (ownership check)
- Create: `t/releases.t`

**Interfaces:**
- Consumes: `$c->session->{developer}`, `Model::Plugin->find`, both already in place.

- [ ] **Step 1: Write failing tests for the new behaviour**

Create `t/releases.t`. It reuses Task 4's package-sub-override technique,
but with the stubbed profile driven by a `login_as` helper so the same test
file can log in as two different, specific, already-seeded developers:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojo::Promise;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;

reset_db();

my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => '1', username => 'owner' }
);
my $other = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => '2', username => 'other' }
);
my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
    { name => 'CoverFlow', developer_id => $owner->id }
);

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

my $profile_to_return;
{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Controller::Auth::_get_oauth_token_p = sub {
        return Mojo::Promise->resolve( { access_token => 'fake-token' } );
    };
    *KohaPluginStore::Controller::Auth::_fetch_github_profile = sub {
        return $profile_to_return;
    };
}

sub login_as {
    my ($developer) = @_;
    $profile_to_return = {
        id         => $developer->provider_user_id,
        login      => $developer->username,
        avatar_url => $developer->avatar_url,
    };
    $t->get_ok('/auth/github')->status_is(302);
}

subtest 'anonymous cannot submit a release' => sub {
    $t->get_ok('/logout');
    $t->post_ok( '/new-release' => form => { plugin_id => $plugin->id } )->status_is(404); # existing #TODO: should be 401
};

subtest 'a different developer cannot submit a release for someone else\'s plugin' => sub {
    login_as($other);
    $t->post_ok(
        '/new-release' => form => {
            plugin_id                         => $plugin->id,
            release_metadata_version          => '1.0.0',
            release_metadata_koha_min_version => '19.05',
        }
    )->status_is(401);
};

subtest 'the owning developer can submit a release' => sub {
    login_as($owner);
    $t->post_ok(
        '/new-release' => form => {
            plugin_id                         => $plugin->id,
            release_metadata_version          => '1.0.0',
            release_metadata_koha_min_version => '19.05',
        }
    )->status_is(302);
};

done_testing();
```

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/releases.t
```
Expected: FAIL — the anonymous-submission subtest currently returns 302 (no auth check exists yet), not 404.

- [ ] **Step 3: Gate the route**

In `lib/KohaPluginStore.pm`, change:
```perl
    $r->post('/new-release')->to('releases#new_release');
```
to:
```perl
    $r->post('/new-release')->requires( user_authenticated => 1 )->to('releases#new_release');
```

- [ ] **Step 4: Add the ownership check to `Releases.pm`**

In `lib/KohaPluginStore/Controller/Releases.pm`, add `use KohaPluginStore::Model::Plugin;` alongside the existing `use KohaPluginStore::Model::PluginVersion;`, and change the start of `new_release`:
```perl
sub new_release ($c) {

    my $plugin_id                = $c->param('plugin_id');
```
to:
```perl
sub new_release ($c) {

    my $plugin_id = $c->param('plugin_id');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { id => $plugin_id } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;
    return $c->render( text => 'Unauthorized', status => 401 )
        unless $c->session->{developer}->{id} == $plugin->developer_id;
```
(leave the rest of the method, including all the `$c->param(...)` reads below it, unchanged)

- [ ] **Step 5: Run `t/releases.t` again to verify it passes**

```bash
prove -l t/releases.t
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore.pm lib/KohaPluginStore/Controller/Releases.pm t/releases.t
git commit -m "Require login and plugin ownership to submit a new release"
```

---

### Task 7: Seed data and remaining test fixes

**Files:**
- Modify: `lib/KohaPluginStore/Command/reset_test_data.pm`
- Modify: `t/api_plugins.t`
- Modify: `t/site.t`

**Interfaces:**
- Consumes: `Model::Developer->create`, `Model::Plugin`'s `developer_id` column (both from earlier tasks).

- [ ] **Step 1: Update `reset_test_data.pm`**

Change:
```perl
use KohaPluginStore::Model::User;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
```
to:
```perl
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
```

Change:
```perl
    $pg->db->query(
        'TRUNCATE plugin_versions, plugins, users RESTART IDENTITY CASCADE'
    );

    # Users data:
    # admin: admin
    # John: Doe
    my $admin = KohaPluginStore::Model::User->new( pg => $pg )->create(
        { username => 'admin', password => 'admin', email => 'admin@www.com' }
    );
    KohaPluginStore::Model::User->new( pg => $pg )->create(
        { username => 'John', password => 'Doe', email => 'john@doe.com' }
    );
```
to:
```perl
    $pg->db->query(
        'TRUNCATE plugin_versions, plugins, developers RESTART IDENTITY CASCADE'
    );

    # Developers data (fake GitHub identities -- can't fabricate a real OAuth login):
    my $admin = KohaPluginStore::Model::Developer->new( pg => $pg )->create(
        { oauth_provider_key => 'github', provider_user_id => '1001', username => 'admin' }
    );
    KohaPluginStore::Model::Developer->new( pg => $pg )->create(
        { oauth_provider_key => 'github', provider_user_id => '1002', username => 'John' }
    );
```

Then change all four remaining `user_id => $admin->id,` lines (in the `CoverFlow`, `IllActions`, `PDFtoCover`, and `LMSEventManagement` plugin `create` calls) to `developer_id => $admin->id,`.

- [ ] **Step 2: Update `t/api_plugins.t`**

Change:
```perl
use KohaPluginStore::Model::User;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $user = KohaPluginStore::Model::User->new( pg => test_pg() )->create(
    { username => 'seeder', password => 'seederpass', email => 'seeder@example.com' }
);
my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
    { name => 'CoverFlow', description => 'A widget', user_id => $user->id }
);
```
to:
```perl
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => '1', username => 'seeder' }
);
my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
    { name => 'CoverFlow', description => 'A widget', developer_id => $developer->id }
);
```

- [ ] **Step 3: Rewrite `t/site.t` for the GitHub flow**

Replace the whole file:
```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojo::Promise;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Controller::Auth::_get_oauth_token_p = sub {
        return Mojo::Promise->resolve( { access_token => 'fake-token' } );
    };
    *KohaPluginStore::Controller::Auth::_fetch_github_profile = sub {
        return { id => '777', login => 'newdev', avatar_url => 'https://example.com/n.png' };
    };
}

subtest 'GitHub login then logout' => sub {
    $t->get_ok('/auth/github')->status_is(302)->header_is( Location => '/my-plugins' );
    $t->get_ok('/logout')->status_is(302);
};

subtest 'my-plugins requires login' => sub {
    $t->get_ok('/my-plugins')->status_is(404); # existing #TODO in the app: this should be 401
};

done_testing();
```

- [ ] **Step 4: Run the full suite**

```bash
prove -l t/
```
Expected: PASS — every file, including `t/api_plugins.t`, `t/site.t`, `t/releases.t`, `t/auth.t`, `t/model_developer.t`, `t/model_base.t`, `t/model_plugin.t`, `t/basic.t`.

- [ ] **Step 5: Manual smoke test — real seed data and a real GitHub login**

```bash
docker compose up -d postgres
script/koha_plugin_store migrate
script/koha_plugin_store reset_test_data
morbo script/koha_plugin_store
```

With a real GitHub OAuth App registered (callback URL `http://127.0.0.1:3000/auth/github`) and its `client_id`/`client_secret` in `koha_plugin_store.conf`'s `oauth_providers` block, visit `http://127.0.0.1:3000/login`, click "Log in with GitHub", authorize, and confirm you land on `/my-plugins` logged in as your GitHub account (a new `developers` row should exist for it). Confirm `/logout` works and `/login` no longer shows a password form.

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore/Command/reset_test_data.pm t/api_plugins.t t/site.t
git commit -m "Update seed data and remaining tests for GitHub OAuth login"
```

---

### Task 8: Update docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Interfaces:**
- None — documentation only.

- [ ] **Step 1: Update `CLAUDE.md`**

In the "Request flow" section, add a note that auth is now GitHub OAuth (`Mojolicious::Plugin::OAuth2`), not a session-condition-only "logged in or not" check against a password-based `users` table — the `user_authenticated` condition and coarse permission model are otherwise unchanged, just re-pointed at `session->{developer}`. Mention `Model::Developer` replacing `Model::User` in the "Data layer" section's model list, and that `plugins.developer_id` replaces `plugins.user_id`.

- [ ] **Step 2: Update `README.md`**

In the "Notes" section, add: local/Docker dev needs a real GitHub OAuth App registered (callback URL matching your `morbo`/Docker host and port) with its `client_id`/`client_secret` added to `koha_plugin_store.conf`'s `oauth_providers` block — there's no password-based login anymore.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "Update docs for GitHub OAuth developer login"
```
