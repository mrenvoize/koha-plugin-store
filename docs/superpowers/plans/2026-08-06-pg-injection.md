# Inject pg Instead of a Singleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `KohaPluginStore::Model::DB`'s class-level `Mojo::Pg` singleton with an injected `pg` attribute, matching [Mojo::Pg's documented GROWING pattern](https://metacpan.org/pod/Mojo::Pg#GROWING) (`has 'pg';` on model classes, wired up via a helper). This is purely axis 2 of a three-axis discussion (shared generic-CRUD base class / singleton-vs-injection / blocking-vs-non-blocking) — the shared `Model::Base` CRUD abstraction stays exactly as it is, and this plan does **not** make anything non-blocking (that's an explicitly separate, larger follow-up: every controller action would need to become async, not just the model layer).

**Architecture:** `KohaPluginStore` (the app class) gains a lazy `has pg => sub { Mojo::Pg->new($self->config->{pg_dsn}) };` attribute — one `Mojo::Pg` instance per app instance, built on first access, exactly mirroring the doc's `state $pg = Mojo::Pg->new(...)` helper pattern but scoped to the app object rather than a bare lexical. `KohaPluginStore::Model::DB` is deleted entirely. `KohaPluginStore::Model::Base` gains `has 'pg'` and `has 'data'` attributes (replacing the hand-written `new`/`_pg`/`_data` machinery — `Mojo::Base -base`'s generated constructor already accepts `->new(pg => ..., data => ...)` for free). Every model construction call site across controllers, commands, and tests must now pass `pg` explicitly — there is no implicit fallback, by design, since the whole point is removing the global.

**Tech Stack:** `Mojo::Base -base` (replacing the hand-written constructor in `Model::Base`), no new dependencies.

## Global Constraints

- No implicit/fallback `pg` lookup anywhere — every `->new(...)` call for a model class must pass `pg` explicitly. If a call site is missing it, that's a bug to fix, not a signal to add a default.
- HTTP-level behaviour must not change: same routes, same redirects, same rendered templates, same session contents. `Controller::Site`'s `login`/`register`/`_log_in_user` are being restructured internally (see Task 3) to eliminate a duplicate DB lookup that existed only because `check_password` used to do its own internal `find` — the external behaviour (what a user experiences) must stay identical.
- `t/lib/TestDB.pm` changes from "initialize a singleton before any test runs" to "expose a shared `Mojo::Pg` instance (`test_pg()`) that call sites inject explicitly, plus `reset_db()` unchanged in effect." Every test file that boots the full app via `Test::Mojo->new('KohaPluginStore')` must override `$t->app->pg(test_pg())` immediately after construction, before dispatching any request — the app's own lazy `pg` builder would otherwise read whatever `pg_dsn` happens to be in the local dev `koha_plugin_store.conf`, not the test database.
- Do not touch `Model::Plugin`'s `_table`/`_columns`, `Model::PluginVersion`, or the migrations/OpenAPI/Docker work from earlier tasks — this plan is scoped to the connection-management axis only.

---

## Task 1: Rewrite `Model::Base`, the app's `pg` attribute, and `TestDB.pm`; delete `Model::DB`

**Files:**
- Modify: `lib/KohaPluginStore.pm`
- Modify: `lib/KohaPluginStore/Model/Base.pm`
- Delete: `lib/KohaPluginStore/Model/DB.pm`
- Modify: `t/lib/TestDB.pm`
- Delete: `t/model_db.t`
- Modify: `t/model_base.t`

**Interfaces:**
- Produces: `KohaPluginStore->pg` (lazy app-instance attribute), `KohaPluginStore::Model::Base->new(pg => $pg, data => \%row)` (or just `pg => $pg` for a fresh, uncreated instance), `TestDB::test_pg()` (shared `Mojo::Pg` for tests), `TestDB::reset_db()` (unchanged in effect).

- [ ] **Step 1: Add the `pg` attribute to `KohaPluginStore.pm`, remove `Model::DB`**

```perl
package KohaPluginStore;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::Pg;

use KohaPluginStore::Model::User;
use KohaPluginStore::Model::Plugin;

has site_name => sub {
    my $app = shift;
    return $app->config->{site_name} || 'Koha Plugin Store';
};

has pg => sub {
    my $self = shift;
    return Mojo::Pg->new( $self->config->{pg_dsn} );
};

sub startup ($self) {

    $self->plugin('Config');

    push @{ $self->commands->namespaces }, 'KohaPluginStore::Command';

    $self->helper( pg => sub { shift->app->pg } );

    $self->helper(
        logged_in_user => sub {
            my ( $c, $user ) = @_;
            $user ||= $c->stash->{user} || $c->session->{user};
            return unless $user;
            return KohaPluginStore::Model::User->new( pg => $c->pg )->find( { username => $user->{username} } )
              || undef;
        }
    );

    $self->_add_routes_authorization();

    my $r = $self->routes;

    $r->any('/')->to('site#index');
    $r->any('/plugins')->to('plugins#index');
    $r->any('/users')->to('users#index');
    $r->get('/login')->to( template => 'login' );
    $r->post('/login')->to('site#login');
    $r->get('/register')->to( template => 'register' );
    $r->post('/register')->to('site#register');
    $r->get('/logout')->to('site#logout');
    $r->get('/my-plugins')->requires( user_authenticated => 1 )->to('plugins#my_plugins');
    $r->get('/new-plugin')->requires( user_authenticated => 1 )->to('plugins#add_form');
    $r->get('/plugins/edit/:id')->requires( user_authenticated => 1 )->to('plugins#edit_form');
    $r->post('/new-plugin')->to('plugins#new_plugin');
    $r->post('/new-plugin-confirm')->to('plugins#new_plugin_confirm');
    $r->post('/new-release')->to('releases#new_release');

    #TODO: Use OpenAPI mojolicious plugin?
    $r->any('/api/plugins')->to('plugins#list_all');
}

sub _add_routes_authorization {
	my $self = shift;

    $self->routes->add_condition(
    	user_authenticated => sub {
    	my ( $r, $c ) = @_;

        if ( defined(  $c->session->{user}->{id} ) ) {
            return 1;
        }

        #TODO: This is currently returning 404. It'd be cool if we could return 401 instead
        return;
    })
}

1;
```

(The `use KohaPluginStore::Model::DB;` import and the eager `KohaPluginStore::Model::DB->pg( $self->config );` line are both gone — `has pg` is lazy, so nothing needs to eagerly initialize it. Everything else in this file — routes, `_add_routes_authorization`, `site_name` — is unchanged.)

- [ ] **Step 2: Delete `Model::DB.pm`**

```bash
git rm lib/KohaPluginStore/Model/DB.pm
```

- [ ] **Step 3: Rewrite `Model::Base.pm`**

```perl
package KohaPluginStore::Model::Base;

use Mojo::Base -base, -signatures;
use Carp qw( croak );

has 'pg';
has 'data';

sub default_query_params {
    return { limit => 10 };
}

sub create {
    my ( $self, $attrs ) = @_;

    my $row = $self->pg->db->insert(
        $self->_table, $attrs, { returning => $self->_columns }
    )->hash;

    return $self->_new_from_row($row);
}

sub find {
    my ( $self, $query ) = @_;

    my $row = $self->pg->db->select( $self->_table, undef, $query, { limit => 1 } )->hash;
    return unless $row;

    return $self->_new_from_row($row);
}

sub search {
    my ( $self, $query, $params ) = @_;

    $query = {} unless $query;
    my $merged = { %{ $self->default_query_params }, %{ $params || {} } };

    my $rows = $self->pg->db->select( $self->_table, undef, $query, $merged )->hashes;

    return map { $self->_new_from_row($_) } @$rows;
}

sub _new_from_row {
    my ( $self, $row ) = @_;
    return ref($self)->new( pg => $self->pg, data => $row );
}

sub unblessed {
    my ($self) = @_;
    return { %{ $self->data } };
}

our $AUTOLOAD;

sub AUTOLOAD {
    my $self = shift;

    my $method = $AUTOLOAD;
    $method =~ s/.*:://;
    return if $method eq 'DESTROY';

    croak( $method . ' is not a column on ' . $self->_table )
        unless $self->data && exists $self->data->{$method};

    if (@_) {
        $self->data->{$method} = shift;
        return $self;
    }

    return $self->data->{$method};
}

1;
```

(No hand-written `new` — `Mojo::Base -base`'s generated constructor already accepts `->new(pg => $pg)` or `->new(pg => $pg, data => \%row)`. `_table`/`_columns` remain plain subs that subclasses override, unchanged from before.)

- [ ] **Step 4: Rewrite `t/lib/TestDB.pm`**

```perl
package TestDB;

use Modern::Perl;
use Exporter 'import';
use Mojo::Pg;

our @EXPORT_OK = qw(reset_db test_pg);

my $DSN = $ENV{KOHA_PLUGIN_STORE_TEST_DSN}
    || 'postgresql://koha_plugin_store:koha_plugin_store@127.0.0.1:55432/koha_plugin_store';

my $PG = Mojo::Pg->new($DSN);

sub test_pg {
    return $PG;
}

sub reset_db {
    $PG->db->query(
        'TRUNCATE plugin_versions, plugins, users RESTART IDENTITY CASCADE'
    );
}

1;
```

- [ ] **Step 5: Delete `t/model_db.t`**

This test verified singleton behaviour (`KohaPluginStore::Model::DB->pg` returns the same instance twice) that no longer exists by design — there is no singleton to test.

```bash
git rm t/model_db.t
```

- [ ] **Step 6: Rewrite `t/model_base.t`**

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Base;

package TestPlugin {
    use Modern::Perl;
    use parent -norequire, 'KohaPluginStore::Model::Base';
    sub _table   { return 'plugins' }
    sub _columns { return [qw(id repo_url name class_name description author thumbnail user_id timestamp)] }
}

reset_db();

subtest 'create returns a populated object' => sub {
    my $plugin = TestPlugin->new( pg => test_pg() )->create( { name => 'Widget', description => 'A widget' } );
    ok( $plugin->id, 'id was assigned' );
    is( $plugin->name, 'Widget', 'name accessor reads back' );
};

subtest 'find locates by column' => sub {
    TestPlugin->new( pg => test_pg() )->create( { name => 'Findable' } );
    my $found = TestPlugin->new( pg => test_pg() )->find( { name => 'Findable' } );
    is( $found->name, 'Findable', 'found the right row' );
    ok( !TestPlugin->new( pg => test_pg() )->find( { name => 'NoSuchThing' } ), 'find returns undef for no match' );
};

subtest 'search returns all matches' => sub {
    reset_db();
    TestPlugin->new( pg => test_pg() )->create( { name => 'A', author => 'Same Author' } );
    TestPlugin->new( pg => test_pg() )->create( { name => 'B', author => 'Same Author' } );
    my @found = TestPlugin->new( pg => test_pg() )->search( { author => 'Same Author' } );
    is( scalar @found, 2, 'both rows found' );
};

subtest 'accessor can set as well as get' => sub {
    my $plugin = TestPlugin->new( pg => test_pg() )->create( { name => 'Settable' } );
    $plugin->description('Updated');
    is( $plugin->description, 'Updated', 'in-memory set works' );
};

subtest 'unblessed returns a plain hashref' => sub {
    my $plugin = TestPlugin->new( pg => test_pg() )->create( { name => 'Unblessable' } );
    my $hash = $plugin->unblessed;
    is( ref($hash), 'HASH', 'is a plain hashref' );
    is( $hash->{name}, 'Unblessable', 'has the right data' );
};

subtest 'unknown column dies' => sub {
    my $plugin = TestPlugin->new( pg => test_pg() )->create( { name => 'Strict' } );
    eval { $plugin->not_a_real_column };
    like( $@, qr/not a column/, 'raises on unknown accessor' );
};

done_testing();
```

- [ ] **Step 7: Run this task's tests**

Run: `prove -l t/model_base.t`
Expected: PASS (6 subtests)

Run: `perl -c lib/KohaPluginStore.pm`
Expected: `lib/KohaPluginStore.pm syntax OK` (the rest of the app won't fully boot yet — Task 2/3 still reference the old `check_password` and un-injected `->new()` call sites — this is just a syntax sanity check for this file in isolation)

- [ ] **Step 8: Commit**

```bash
git add lib/KohaPluginStore.pm lib/KohaPluginStore/Model/Base.pm t/lib/TestDB.pm t/model_base.t
git add -u
git commit -m "Inject pg into models instead of a class-level singleton

Replaces KohaPluginStore::Model::DB's package-level Mojo::Pg singleton with
a lazy 'pg' attribute on the app class, matching Mojo::Pg's documented
GROWING pattern (has 'pg' on models, wired via a helper) instead of a
global class-method lookup. This is purely the connection-management axis
of the design — the shared Model::Base CRUD abstraction is unchanged, and
nothing here makes any query non-blocking (that's a separate, larger
follow-up touching every controller action)."
```

---

## Task 2: Update `Model::Plugin`/`Model::User` for injected pg; fix `check_password`

**Files:**
- Modify: `lib/KohaPluginStore/Model/Plugin.pm`
- Modify: `lib/KohaPluginStore/Model/User.pm`
- Modify: `t/model_plugin.t`
- Modify: `t/model_user.t`

**Interfaces:**
- Produces: `KohaPluginStore::Model::Plugin::releases()` passes its own `pg` through when constructing related `PluginVersion` objects. `KohaPluginStore::Model::User::check_password` becomes an **instance method** taking just `$password` (checks the password against the instance it's called on), replacing the old bare-function form `check_password($username, $password)` that did its own internal `find`.

- [ ] **Step 1: Update `Model::Plugin.pm`**

Only `releases()` changes — it must pass its own `pg` when constructing the related `PluginVersion` model:

```perl
package KohaPluginStore::Model::Plugin;

use Modern::Perl;
use parent -norequire, 'KohaPluginStore::Model::Base';

use KohaPluginStore::Model::PluginVersion;

sub _table {
    return 'plugins';
}

sub _columns {
    return [qw(id repo_url name class_name description author thumbnail user_id timestamp)];
}

sub releases {
    my ($self) = @_;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => $self->pg )->search( { plugin_id => $self->id } );
    return \@versions;
}

1;
```

- [ ] **Step 2: Update `Model::User.pm` — `check_password` becomes an instance method**

```perl
package KohaPluginStore::Model::User;

use Modern::Perl;
use Carp ();
use parent -norequire, 'KohaPluginStore::Model::Base';

use Passwords ();

sub _table {
    return 'users';
}

sub _columns {
    return [qw(id username password email)];
}

sub check_password {
    my ( $self, $password ) = @_;

    return undef unless $password;
    return Passwords::password_verify( $password, $self->password );
}

sub create {
    my ( $self, $attrs ) = @_;

    Carp::croak('password is required') unless $attrs->{password};
    $attrs->{password} = Passwords::password_hash( $attrs->{password} );

    return $self->SUPER::create($attrs);
}

1;
```

This is a deliberate behaviour-preserving simplification, not a leftover from the pg-injection change alone: `check_password` used to be a bare function that did its own internal `find` by username — every caller (`Controller::Site::login`) therefore did two separate DB round-trips (one inside `check_password`, one right after inside `_log_in_user`, which looked the user up *again* by username). As an instance method, the caller finds the user once and both checks the password and logs them in from the same instance (see Task 3). `check_password`'s old signature had no natural way to receive an injected `pg` at all (it was a plain function, no `$self`) — becoming a method is the only sensible fix that keeps it consistent with the rest of this codebase's injection design.

- [ ] **Step 3: Update `t/model_plugin.t`**

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

subtest 'plugin releases returns its versions' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'CoverFlow' } );

    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, version => '2.5.7', tag_name => 'v2.5.7' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, version => '2.5.8', tag_name => 'v2.5.8' }
    );

    my $versions = $plugin->releases;
    is( scalar @$versions, 2, 'both versions returned' );
    is( ( sort map { $_->version } @$versions )[0], '2.5.7', 'version accessor works on the related object' );
};

done_testing();
```

- [ ] **Step 4: Update `t/model_user.t`**

`check_password` is now called on a found instance, not as a bare function:

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::User;

reset_db();

subtest 'create hashes the password' => sub {
    my $user = KohaPluginStore::Model::User->new( pg => test_pg() )->create(
        { username => 'admin', password => 'admin', email => 'admin@example.com' }
    );
    isnt( $user->password, 'admin', 'password is not stored in plain text' );
};

subtest 'check_password verifies correctly' => sub {
    KohaPluginStore::Model::User->new( pg => test_pg() )->create(
        { username => 'jdoe', password => 'secret123', email => 'jdoe@example.com' }
    );
    my $found = KohaPluginStore::Model::User->new( pg => test_pg() )->find( { username => 'jdoe' } );
    ok( $found->check_password('secret123'), 'correct password verifies' );
    ok( !$found->check_password('wrongpassword'), 'wrong password fails' );
    ok( !KohaPluginStore::Model::User->new( pg => test_pg() )->find( { username => 'nosuchuser' } ), 'unknown user is not found at all' );
};

subtest 'create requires a password' => sub {
    eval { KohaPluginStore::Model::User->new( pg => test_pg() )->create( { username => 'nopass', email => 'x@example.com' } ) };
    like( $@, qr/password is required/, 'raises without a password' );
};

done_testing();
```

- [ ] **Step 5: Run this task's tests**

Run: `prove -l t/model_plugin.t t/model_user.t`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore/Model/Plugin.pm lib/KohaPluginStore/Model/User.pm t/model_plugin.t t/model_user.t
git commit -m "Update Plugin/User models for injected pg; check_password becomes an instance method"
```

---

## Task 3: Update controllers and app-boot test files

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm`
- Modify: `lib/KohaPluginStore/Controller/Releases.pm`
- Modify: `lib/KohaPluginStore/Controller/Site.pm`
- Modify: `lib/KohaPluginStore/Controller/Users.pm`
- Modify: `t/basic.t`
- Modify: `t/site.t`
- Modify: `t/api_plugins.t`
- Modify: `t/openapi_ping.t`

**Interfaces:**
- Consumes: the `pg` helper registered in Task 1 (`$c->pg`).
- Produces: identical HTTP-level behaviour to before this plan — same routes, same redirects, same rendered output.

- [ ] **Step 1: Update `Controller::Plugins.pm`**

Every `KohaPluginStore::Model::Plugin->new()` / `KohaPluginStore::Model::PluginVersion->new()` call site in this file gets `pg => $c->pg` added. This file also has extensive GitHub-fetching/download/metadata-parsing logic — none of that changes, only the model-construction lines. The affected lines (each `->new()` becomes `->new( pg => $c->pg )`):

- `index`: `KohaPluginStore::Model::Plugin->new()->search;`
- `my_plugins`: `KohaPluginStore::Model::Plugin->new()->search( { user_id => $c->session->{user}->{id} } );`
- `edit_form`: `KohaPluginStore::Model::Plugin->new()->find(...)`
- `list_all`: `KohaPluginStore::Model::Plugin->new()->search;` and `KohaPluginStore::Model::PluginVersion->new()->search(...)`
- `new_plugin`: `KohaPluginStore::Model::Plugin->new()->find(...)`
- `new_plugin_confirm`: `KohaPluginStore::Model::Plugin->new()->create(...)` and `KohaPluginStore::Model::PluginVersion->new()->create(...)`

In every case, replace `->new()` (or `->new`) with `->new( pg => $c->pg )` — `$c` is already in scope in every one of these subs (they're all controller actions receiving `$c` as their first argument). Do not change anything else in this file — no reformatting, no touching the GitHub/download/metadata-parsing subs.

- [ ] **Step 2: Update `Controller::Releases.pm`**

```perl
package KohaPluginStore::Controller::Releases;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::PluginVersion;
use JSON;

sub new_release ($c) {

    my $plugin_id                = $c->param('plugin_id');
    my $release_name             = $c->param('release_metadata_name');
    my $release_tag_name         = $c->param('release_metadata_tag_name');
    my $release_date_released    = $c->param('release_metadata_date_released');
    my $release_version          = $c->param('release_metadata_version');
    my $release_koha_min_version = $c->param('release_metadata_koha_min_version');
    my $release_kpz_url          = $c->param('kpz_download');

    my $new_release = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->create(
        {
            plugin_id        => $plugin_id,
            name             => $release_name,
            tag_name         => $release_tag_name,
            date_released    => $release_date_released,
            version          => $release_version,
            koha_min_version => $release_koha_min_version,
            kpz_url          => $release_kpz_url
        }
    );

    $c->stash( plugin_id => $plugin_id );
    $c->render('releases/new-release-confirm');
}

1;
```

- [ ] **Step 3: Update `Controller::Site.pm`**

`login`/`register`/`_log_in_user` are restructured to use the new instance-method `check_password` and avoid the duplicate lookup described in Task 2:

```perl
package KohaPluginStore::Controller::Site;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::User;

sub index {
    my $c = shift;

    my @users = KohaPluginStore::Model::User->new( pg => $c->pg )->search;
    my @plugins = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search;
    $c->stash( plugins => \@plugins );
    $c->stash( users   => \@users );
    $c->render;
}

sub login {
    my $c        = shift;
    my $username = $c->param('username');
    my $password = $c->param('password');

    my $user = KohaPluginStore::Model::User->new( pg => $c->pg )->find( { username => $username } );

    if ( $user && $user->check_password($password) ) {
        $c->_log_in_user($user);
        $c->redirect_to('/my-plugins');
    }
    $c->stash( invalid_login => 1 );
    $c->render('login');
}

sub register {
    my $c        = shift;
    my $username = $c->param('username');
    my $user     = {
        username => $username,
        password => $c->param('password'),
        email    => $c->param('email'),
    };
    warn Mojo::Util::dumper $user;
    my $created_user;
    unless (
        eval {
            $created_user = KohaPluginStore::Model::User->new( pg => $c->pg )->create($user);
            1;
        }
      )
    {
        $c->app->log->error($@) if $@;
        return $c->render( text => 'Could not create user', status => 400 );
    }
    $c->_log_in_user($created_user);
    $c->redirect_to('/');
}

sub logout {
    my $c = shift;
    $c->session( expires => 1 );
    $c->redirect_to('/');
}

sub _log_in_user {
    my ( $c, $user ) = @_;
    $c->session->{user} = $user->unblessed;
}
1;
```

(The `warn Mojo::Util::dumper $user;` debug line is pre-existing and out of scope for this plan — leave it exactly as it is, don't remove it as a "while we're here" cleanup.)

- [ ] **Step 4: Update `Controller::Users.pm`**

```perl
package KohaPluginStore::Controller::Users;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use KohaPluginStore::Model::User;

sub index {
    my $c = shift;

    my @users = KohaPluginStore::Model::User->new( pg => $c->pg )->search();

    $c->stash( users => \@users );
    $c->render;
}

1;
```

- [ ] **Step 5: Update `t/basic.t`**

Add the `pg` override right after constructing `Test::Mojo`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

$t->get_ok('/')->status_is(200)->content_like(qr/Koha Plugin Store/i);

done_testing();
```

- [ ] **Step 6: Update `t/site.t`**

Same pattern — add `$t->app->pg( test_pg() );` right after `Test::Mojo->new`, and update the `use TestDB` import line to include `test_pg`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

subtest 'register then login' => sub {
    $t->post_ok(
        '/register' => form => {
            username => 'newdev',
            password => 'devpassword',
            email    => 'newdev@example.com',
        }
    )->status_is(302);

    $t->get_ok('/logout')->status_is(302);

    $t->post_ok(
        '/login' => form => { username => 'newdev', password => 'devpassword' }
    )->status_is(302);
};

subtest 'my-plugins requires login' => sub {
    $t->get_ok('/logout')->status_is(302);
    $t->get_ok('/my-plugins')->status_is(404); # existing #TODO in the app: this should be 401
};

done_testing();
```

- [ ] **Step 7: Update `t/api_plugins.t`**

Add `test_pg()` to both the seed-data construction calls and the `Test::Mojo` override:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

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
KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
    {
        plugin_id        => $plugin->id,
        version          => '2.5.7',
        koha_min_version => '19.05',
        date_released    => '2024-07-01T15:34:06Z',
    }
);

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

subtest 'requires koha_version_release' => sub {
    $t->get_ok('/api/plugins')->status_is(400);
};

subtest 'lists the seeded plugin and its compatible release' => sub {
    $t->get_ok('/api/plugins?koha_version_release=20.00')
      ->status_is(200)
      ->json_is( '/0/name' => 'CoverFlow' )
      ->json_is( '/0/releases/0/version' => '2.5.7' )
      ->header_is( 'Access-Control-Allow-Origin' => '*' );
};

done_testing();
```

- [ ] **Step 8: Update `t/openapi_ping.t`**

The `/api/v1/ping` route doesn't touch the database at all, but add the override anyway for consistency with every other app-booting test file (defensive — avoids this test being the one exception that silently relies on a real `koha_plugin_store.conf` existing):

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(test_pg);

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

subtest 'ping responds per the OpenAPI spec' => sub {
    $t->get_ok('/api/v1/ping')
      ->status_is(200)
      ->json_is( '/status' => 'ok' );
};

subtest 'undefined operations are rejected by the router' => sub {
    $t->post_ok('/api/v1/ping')->status_is(404);
};

done_testing();
```

- [ ] **Step 9: Run the full test suite**

Run: `prove -l t/`
Expected: all PASS

- [ ] **Step 10: Manual smoke test**

Ensure `koha_plugin_store.conf` exists and Postgres is running, then:

Run: `script/koha_plugin_store reset_test_data`
Expected: `Test data reset.` (this won't fully work until Task 4 updates the commands — if it fails here because `migrate`/`reset_test_data` still reference the deleted `Model::DB`, that's expected; note it in your report and don't attempt to fix Task 4's files from within this task)

- [ ] **Step 11: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm lib/KohaPluginStore/Controller/Releases.pm lib/KohaPluginStore/Controller/Site.pm lib/KohaPluginStore/Controller/Users.pm t/basic.t t/site.t t/api_plugins.t t/openapi_ping.t
git commit -m "Wire controllers to the injected pg helper; simplify Site's login/register flow"
```

---

## Task 4: Update the Mojolicious::Command classes

**Files:**
- Modify: `lib/KohaPluginStore/Command/migrate.pm`
- Modify: `lib/KohaPluginStore/Command/reset_test_data.pm`

**Interfaces:**
- Consumes: `$self->app->pg` (commands run inside a fully-booted app, so this is the same `pg` attribute controllers use via the helper).

- [ ] **Step 1: Update `migrate.pm`**

```perl
package KohaPluginStore::Command::migrate;
use Mojo::Base 'Mojolicious::Command', -signatures;

has description => 'Apply Postgres migrations';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $pg = $self->app->pg;
    $pg->migrations->from_data(__PACKAGE__)->migrate;

    say 'Migrated to version ' . $pg->migrations->latest;
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::migrate - Apply Postgres migrations

=head1 SYNOPSIS

  Usage: APPLICATION migrate

=cut

__DATA__

@@ migrations
-- 1 up
CREATE TABLE users (
    id       SERIAL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    email    TEXT UNIQUE NOT NULL
);

CREATE TABLE plugins (
    id          SERIAL PRIMARY KEY,
    repo_url    TEXT UNIQUE,
    name        TEXT UNIQUE,
    class_name  TEXT UNIQUE,
    description TEXT,
    author      TEXT,
    thumbnail   TEXT,
    user_id     INTEGER REFERENCES users(id) ON DELETE CASCADE,
    "timestamp" TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE plugin_versions (
    id               SERIAL PRIMARY KEY,
    plugin_id        INTEGER REFERENCES plugins(id) ON DELETE CASCADE,
    name             TEXT,
    tag_name         TEXT,
    version          TEXT,
    koha_min_version TEXT,
    kpz_url          TEXT,
    date_released    TIMESTAMPTZ
);

-- 1 down
DROP TABLE plugin_versions;
DROP TABLE plugins;
DROP TABLE users;
```

(Only change from the current file: drop `use KohaPluginStore::Model::DB;` and replace `KohaPluginStore::Model::DB->pg` with `$self->app->pg`. The `__DATA__` section is unchanged.)

- [ ] **Step 2: Update `reset_test_data.pm`**

Same pattern — drop the `Model::DB` import, use `$self->app->pg`, and pass `pg => $pg` to every model construction call:

```perl
package KohaPluginStore::Command::reset_test_data;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::Model::User;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

has description => 'Wipe and reseed demo users/plugins/releases';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $pg = $self->app->pg;

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

    my $coverflow = KohaPluginStore::Model::Plugin->new( pg => $pg )->create(
        {
            author      => 'Kyle M Hall',
            class_name  => 'Koha::Plugin::Com::ByWaterSolutions::CoverFlow',
            description => 'Convert a report into a coverflow style widget!',
            name        => 'CoverFlow plugin',
            repo_url    => 'https://github.com/bywatersolutions/koha-plugin-coverflow',
            thumbnail   => 'coverflow.png',
            timestamp   => '2024-09-17 09:34:22',
            user_id     => $admin->id,
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => $pg )->create(
        {
            plugin_id        => $coverflow->id,
            name             => 'v2.5.7',
            tag_name         => 'v2.5.7',
            version          => '2.5.7',
            koha_min_version => '19.05',
            kpz_url          => 'https://github.com/bywatersolutions/koha-plugin-coverflow/releases/download/v2.5.7/koha-plugin-coverflow-2.5.7.kpz',
            date_released    => '2024-07-01T15:34:06Z',
        }
    );

    my $ill_actions = KohaPluginStore::Model::Plugin->new( pg => $pg )->create(
        {
            author      => 'PTFS-Europe',
            class_name  => 'Koha::Plugin::Com::PTFSEurope::IllActions',
            description => 'ILL Actions',
            name        => 'IllActions',
            repo_url    => 'https://github.com/PTFS-Europe/koha-plugin-ill-actions',
            thumbnail   => 'ill_actions.png',
            timestamp   => '2024-09-17 09:53:10',
            user_id     => $admin->id,
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => $pg )->create(
        {
            plugin_id        => $ill_actions->id,
            name             => 'v1.3.1',
            tag_name         => '1.3.1',
            version          => '1.3.1',
            koha_min_version => '23.11.00.000',
            kpz_url          => 'https://github.com/PTFS-Europe/koha-plugin-ill-actions/releases/download/1.3.1/koha-ill-actions-plugin-1.3.1.kpz',
            date_released    => '2024-03-27T15:56:15Z',
        }
    );

    my $pdf_to_cover = KohaPluginStore::Model::Plugin->new( pg => $pg )->create(
        {
            author      => 'Mehdi Hamidi, Bouzid Fergani, Arthur Bousquet, The Minh Luong, Matthias Le Gac',
            class_name  => 'Koha::Plugin::PDFtoCover',
            description => 'Creates cover images for documents missing one',
            name        => 'PDFtoCover',
            repo_url    => 'https://github.com/inLibro/koha-plugin-pdftocover',
            thumbnail   => 'pdftocover.png',
            timestamp   => '2024-09-17 10:12:51',
            user_id     => $admin->id,
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => $pg )->create(
        {
            plugin_id        => $pdf_to_cover->id,
            name             => 'v2.1',
            tag_name         => 'v2.1',
            version          => '2.1',
            koha_min_version => '23.05.08',
            kpz_url          => 'https://github.com/inLibro/koha-plugin-pdftocover/releases/download/v2.1/koha-plugin-pdftocover-2.1.kpz',
            date_released    => '2024-07-30T19:18:58Z',
        }
    );

    my $lms_event_management = KohaPluginStore::Model::Plugin->new( pg => $pg )->create(
        {
            author      => 'LMSCloud GmbH',
            class_name  => 'Koha::Plugin::Com::LMSCloud::EventManagement',
            description => 'This plugin makes managing events with koha a breeze!',
            name        => 'LMSEventManagement',
            repo_url    => 'https://github.com/LMSCloud/LMSEventManagement',
            thumbnail   => 'lmscloudevent.png',
            timestamp   => '2024-09-17 11:29:28',
            user_id     => $admin->id,
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => $pg )->create(
        {
            plugin_id        => $lms_event_management->id,
            name             => 'Carnival',
            tag_name         => 'v1.6.12-beta.14',
            version          => '1.6.12',
            koha_min_version => '18.05',
            kpz_url          => 'https://github.com/LMSCloud/LMSEventManagement/releases/download/v1.6.12-beta.14/lms-event-management-v1.6.12.kpz',
            date_released    => '2024-03-04T12:32:26Z',
        }
    );

    say 'Test data reset.';
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::reset_test_data - Wipe and reseed demo data

=head1 SYNOPSIS

  Usage: APPLICATION reset_test_data

=cut
```

- [ ] **Step 3: Verify everything end-to-end**

Ensure `koha_plugin_store.conf` exists and Postgres is running (drop and recreate tables first if a previous run left them in place: `docker compose exec postgres psql -U koha_plugin_store -c 'DROP TABLE IF EXISTS plugin_versions, plugins, users;'`).

Run: `script/koha_plugin_store migrate`
Expected: `Migrated to version 1`

Run: `script/koha_plugin_store reset_test_data`
Expected: `Test data reset.`

Run: `prove -l t/`
Expected: all PASS

Run: `docker compose up -d --build && docker compose exec app script/koha_plugin_store migrate && docker compose exec app script/koha_plugin_store reset_test_data`
Expected: both succeed inside the container too

Manual smoke: `curl -s http://127.0.0.1:3000/ | grep -o 'Koha Plugin Store'`, and exercise register/login/logout via the browser or curl, confirming behaviour matches what it was before this plan (same redirects, same session behaviour).

- [ ] **Step 4: Commit**

```bash
git add lib/KohaPluginStore/Command/migrate.pm lib/KohaPluginStore/Command/reset_test_data.pm
git commit -m "Update Mojolicious::Command classes for injected pg"
```

---

## Task 5: Update documentation

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- None — documentation only.

- [ ] **Step 1: Update the "Data layer" section**

Read `CLAUDE.md`'s current "Data layer" section in this worktree and update it to describe the injected-`pg` design instead of the singleton: `KohaPluginStore` (the app class) holds a lazy `pg` attribute; `Model::Base` subclasses take `pg` via constructor injection (`has 'pg'`, `has 'data'`, no singleton class); controllers access it via the `$c->pg` helper, commands via `$self->app->pg`. Remove any remaining mention of `KohaPluginStore::Model::DB` as a class — it no longer exists.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Update docs for injected pg instead of a Model::DB singleton"
```
