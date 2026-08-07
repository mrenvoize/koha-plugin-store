# Phase 1: Postgres Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace this app's SQLite + DBIx::Class persistence layer with Postgres + `Mojo::Pg`, with zero user-visible behaviour change, and stand up a minimal OpenAPI-validated route as the seed of the future public API contract.

**Architecture:** A local Postgres (via `docker-compose`) replaces `database.db`. A single `Mojo::Pg` connection singleton (`KohaPluginStore::Model::DB`) replaces the DBIx::Class schema. `KohaPluginStore::Model::Base` becomes a thin hand-written CRUD wrapper over `Mojo::Pg`'s query builder (`select`/`insert`) instead of an AUTOLOAD shim over a DBIx::Class result row — but keeps the exact same public interface (`new`, `create`, `find`, `search`, column accessors via method calls, `unblessed`) so every existing controller and template keeps working unchanged except for import/class-name updates. `releases` is renamed to `plugin_versions` (and `Model::Release` to `Model::PluginVersion`) now, while the table is still simple, to avoid a second rename once Phase 4/5 add columns to it. No new features land in this phase — this is a pure infrastructure swap, verified by porting every existing code path across.

**Tech Stack:** Mojolicious (unchanged), `Mojo::Pg` (new, replaces `DBIx::Class`/`Mojo::SQLite`), Postgres 16 via `docker-compose` (new, replaces `database.db`), `Mojolicious::Plugin::OpenAPI` (new, minimal scaffold only).

## Global Constraints

- Zero user-visible behaviour change in this phase — no new features, no schema semantics beyond what's needed to move off SQLite. Anything from the spec that depends on OAuth, checks/levels, or signing (Phases 2+) is explicitly out of scope here.
- Preserve commit history on renamed files: use `git mv` for `Release.pm` → `PluginVersion.pm`, not delete-and-recreate.
- Config-driven DB connection: the hardcoded SQLite DSN in `Model::DB.pm` is replaced by a `pg_dsn` key read from `koha_plugin_store.conf` (same file, same loading convention the app already uses for `github_user_access_token`).
- The store never hosts `.kpz` binaries or performs object storage — not relevant to this phase's schema (no `plugin_versions` columns for it exist yet), but don't introduce anything that assumes otherwise.
- Local Postgres runs via `docker-compose`, not a bare-metal install or a shared server.
- Every test file that touches the database or boots the app must `use lib 't/lib'; use TestDB qw(reset_db);` before doing so, so it always targets the test DSN regardless of what's in the gitignored `koha_plugin_store.conf`.
- `search()` preserves the existing (undocumented, possibly accidental) default `LIMIT 10` behaviour from `Model::Base::default_query_params` — fixing that is explicitly deferred to the discovery-API work in Phase 6, not this phase.

---

## Task 1: Local Postgres via docker-compose

**Files:**
- Create: `docker-compose.yml`

**Interfaces:**
- Produces: a Postgres 16 instance reachable at `postgresql://koha_plugin_store:koha_plugin_store@127.0.0.1:55432/koha_plugin_store` — every later task's DSN.

- [ ] **Step 1: Write the compose file**

```yaml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: koha_plugin_store
      POSTGRES_PASSWORD: koha_plugin_store
      POSTGRES_DB: koha_plugin_store
    ports:
      - "55432:5432"
    volumes:
      - koha_plugin_store_pgdata:/var/lib/postgresql/data

volumes:
  koha_plugin_store_pgdata:
```

(Port `55432` rather than the default `5432` avoids clashing with any Postgres already running locally, e.g. for other projects.)

- [ ] **Step 2: Start it and verify it's reachable**

Run: `docker compose up -d postgres && docker compose exec postgres pg_isready -U koha_plugin_store`
Expected: `/var/run/postgresql:5432 - accepting connections`

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "Add docker-compose Postgres service for local dev/test"
```

---

## Task 2: Migrations, initial schema, and test DB helper

**Files:**
- Modify: `cpanfile`
- Create: `migrations/koha_plugin_store.sql`
- Create: `lib/KohaPluginStore/Command/migrate.pl`
- Create: `t/lib/TestDB.pm`

**Interfaces:**
- Consumes: Postgres running at the DSN from Task 1.
- Produces: `users`, `plugins`, `plugin_versions` tables. `TestDB::reset_db()` — truncates all three (importable by every later test file).

- [ ] **Step 1: Update cpanfile**

Add `Mojo::Pg`, remove the now-unused SQLite/DBIx::Class dependencies:

```
requires 'Modern::Perl';
requires 'Mojolicious';
requires 'Mojo::Pg';
requires 'JSON';
requires 'Passwords';
requires 'Archive::Zip';
requires 'String::Util';
requires 'IO::Socket::SSL';
requires 'Net::SSLeay';
```

(Dropped: `Mojo::SQLite`, `DBIx::Class::Schema`, `Data::Structure::Util` — none are used once Tasks 3–5 land.)

- [ ] **Step 2: Install the new dependency**

Run: `cpanm --installdeps .`
Expected: completes without error, `Mojo::Pg` now available.

- [ ] **Step 3: Write the migration file**

This ports today's SQLite schema (`lib/KohaPluginStore/Command/create_db_schema.pl`) to Postgres, renaming `releases` to `plugin_versions`, with two deliberate corrections: `plugins.user_id` becomes a real `INTEGER` (it was `TEXT` in SQLite despite referencing an integer PK — SQLite's loose typing let that slide, Postgres won't), and `plugin_versions.plugin_id` gets an actual `FOREIGN KEY` constraint (the DBIx::Class `Result` classes already modeled this relationship in Perl; the raw SQLite DDL never enforced it in the database — this migration is where it starts being enforced for real).

```sql
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

(`"timestamp"` is quoted because it's a Postgres type name as well as a valid identifier — quoting avoids any ambiguity. Every other column name is unchanged from today's schema, so nothing that already renders `$plugin->author`, `$release->tag_name`, etc. needs to change.)

- [ ] **Step 4: Write the migration-runner script**

```perl
#!/usr/bin/env perl
use Modern::Perl;
use Mojo::File qw(curfile);
use Mojo::Pg;

my $root = curfile->dirname->sibling('..');
my $dsn  = $ENV{KOHA_PLUGIN_STORE_PG_DSN}
    || 'postgresql://koha_plugin_store:koha_plugin_store@127.0.0.1:55432/koha_plugin_store';

my $pg = Mojo::Pg->new($dsn);
$pg->migrations->from_file( $root->child('migrations', 'koha_plugin_store.sql') )->migrate;

say 'Migrated to version ' . $pg->migrations->latest;
```

- [ ] **Step 5: Run it and verify the schema**

Run: `perl lib/KohaPluginStore/Command/migrate.pl`
Expected: `Migrated to version 1`

Run: `docker compose exec postgres psql -U koha_plugin_store -c '\dt'`
Expected: lists `users`, `plugins`, `plugin_versions`.

- [ ] **Step 6: Write the test DB helper**

```perl
package TestDB;

use Modern::Perl;
use Exporter 'import';

use KohaPluginStore::Model::DB;

our @EXPORT_OK = qw(reset_db);

my $DSN = $ENV{KOHA_PLUGIN_STORE_TEST_DSN}
    || 'postgresql://koha_plugin_store:koha_plugin_store@127.0.0.1:55432/koha_plugin_store';

KohaPluginStore::Model::DB->pg( { pg_dsn => $DSN } );

sub reset_db {
    KohaPluginStore::Model::DB->pg->db->query(
        'TRUNCATE plugin_versions, plugins, users RESTART IDENTITY CASCADE'
    );
}

1;
```

This references `KohaPluginStore::Model::DB->pg`, which doesn't exist until Task 3 — that's expected; this file isn't imported by anything until then.

- [ ] **Step 7: Commit**

```bash
git add cpanfile migrations/koha_plugin_store.sql lib/KohaPluginStore/Command/migrate.pl t/lib/TestDB.pm
git commit -m "Add Postgres migrations, migration runner, and test DB helper"
```

---

## Task 3: `Model::DB` — config-driven `Mojo::Pg` singleton

**Files:**
- Modify: `lib/KohaPluginStore/Model/DB.pm`
- Test: `t/model_db.t`

**Interfaces:**
- Consumes: a config hashref containing `pg_dsn` (from `koha_plugin_store.conf` in production, from `TestDB` in tests).
- Produces: `KohaPluginStore::Model::DB->pg($config)` — returns a `Mojo::Pg` instance, creating it on first call and caching it; `KohaPluginStore::Model::DB->pg()` (no args) returns the cached instance or dies if none exists yet.

- [ ] **Step 1: Write the failing test**

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB;

use KohaPluginStore::Model::DB;

subtest 'returns the same instance on repeat calls' => sub {
    my $first  = KohaPluginStore::Model::DB->pg;
    my $second = KohaPluginStore::Model::DB->pg;
    is( $first, $second, 'singleton returned' );
};

subtest 'can run a trivial query' => sub {
    my $result = KohaPluginStore::Model::DB->pg->db->query('SELECT 1 AS one')->hash;
    is( $result->{one}, 1, 'query round-trips' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/model_db.t`
Expected: FAIL — `Can't locate object method "pg" via package "KohaPluginStore::Model::DB"`

- [ ] **Step 3: Rewrite `Model::DB.pm`**

```perl
package KohaPluginStore::Model::DB;

use Modern::Perl;
use Carp qw( croak );
use Mojo::Pg;

my $pg;

sub pg {
    my ( $class, $config ) = @_;

    return $pg if $pg;

    croak('pg_dsn is required (pass a config hashref on the first call)')
        unless $config && $config->{pg_dsn};

    $pg = Mojo::Pg->new( $config->{pg_dsn} );

    return $pg;
}

1;
```

(This drops the old `new`/`config` methods entirely — nothing outside this file called them directly except `Model::Base`, which Task 4 rewrites to call `pg()` instead.)

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/model_db.t`
Expected: PASS (2 subtests)

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Model/DB.pm t/model_db.t
git commit -m "Replace DBIx::Class schema connection with a Mojo::Pg singleton"
```

---

## Task 4: `Model::Base` — thin `Mojo::Pg` CRUD wrapper

**Files:**
- Modify: `lib/KohaPluginStore/Model/Base.pm`
- Test: `t/model_base.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Model::DB->pg` (Task 3).
- Produces: `new()`, `create(\%attrs)`, `find(\%query)`, `search(\%query, \%params)`, `unblessed()`, column accessors via method calls (e.g. `->id`, `->name`), all as before. Subclasses must implement `_table` (returns the table name string) and `_columns` (returns an arrayref of column names, used for `INSERT ... RETURNING`).

- [ ] **Step 1: Write the failing test**

This test exercises `Model::Base` directly against the `plugins` table via a tiny throwaway subclass defined inline in the test file — `plugins` has no required foreign keys, making it the simplest table to prove the base class against.

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db);

use KohaPluginStore::Model::Base;

package TestPlugin {
    use Modern::Perl;
    use parent -norequire, 'KohaPluginStore::Model::Base';
    sub _table   { return 'plugins' }
    sub _columns { return [qw(id repo_url name class_name description author thumbnail user_id timestamp)] }
}

reset_db();

subtest 'create returns a populated object' => sub {
    my $plugin = TestPlugin->new->create( { name => 'Widget', description => 'A widget' } );
    ok( $plugin->id, 'id was assigned' );
    is( $plugin->name, 'Widget', 'name accessor reads back' );
};

subtest 'find locates by column' => sub {
    TestPlugin->new->create( { name => 'Findable' } );
    my $found = TestPlugin->new->find( { name => 'Findable' } );
    is( $found->name, 'Findable', 'found the right row' );
    ok( !TestPlugin->new->find( { name => 'NoSuchThing' } ), 'find returns undef for no match' );
};

subtest 'search returns all matches' => sub {
    reset_db();
    TestPlugin->new->create( { name => 'A', author => 'Same Author' } );
    TestPlugin->new->create( { name => 'B', author => 'Same Author' } );
    my @found = TestPlugin->new->search( { author => 'Same Author' } );
    is( scalar @found, 2, 'both rows found' );
};

subtest 'accessor can set as well as get' => sub {
    my $plugin = TestPlugin->new->create( { name => 'Settable' } );
    $plugin->description('Updated');
    is( $plugin->description, 'Updated', 'in-memory set works' );
};

subtest 'unblessed returns a plain hashref' => sub {
    my $plugin = TestPlugin->new->create( { name => 'Unblessable' } );
    my $hash = $plugin->unblessed;
    is( ref($hash), 'HASH', 'is a plain hashref' );
    is( $hash->{name}, 'Unblessable', 'has the right data' );
};

subtest 'unknown column dies' => sub {
    my $plugin = TestPlugin->new->create( { name => 'Strict' } );
    eval { $plugin->not_a_real_column };
    like( $@, qr/not a column/, 'raises on unknown accessor' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/model_base.t`
Expected: FAIL — `create` etc. don't exist yet on the rewritten class (or old DBIx::Class-based code errors out against a Postgres handle it doesn't understand)

- [ ] **Step 3: Rewrite `Model::Base.pm`**

```perl
package KohaPluginStore::Model::Base;

use Modern::Perl;
use Carp qw( croak );

use KohaPluginStore::Model::DB;

sub new {
    my ($class) = @_;
    return bless { _data => undef }, $class;
}

sub _pg {
    return KohaPluginStore::Model::DB->pg;
}

sub default_query_params {
    return { limit => 10 };
}

sub create {
    my ( $self, $attrs ) = @_;

    my $row = $self->_pg->db->insert(
        $self->_table, $attrs, { returning => $self->_columns }
    )->hash;

    return $self->_new_from_row($row);
}

sub find {
    my ( $self, $query ) = @_;

    my $row = $self->_pg->db->select( $self->_table, undef, $query, { limit => 1 } )->hash;
    return unless $row;

    return $self->_new_from_row($row);
}

sub search {
    my ( $self, $query, $params ) = @_;

    $query = {} unless $query;
    my $merged = { %{ $self->default_query_params }, %{ $params || {} } };

    my $rows = $self->_pg->db->select( $self->_table, undef, $query, $merged )->hashes;

    return map { $self->_new_from_row($_) } @$rows;
}

sub _new_from_row {
    my ( $self, $row ) = @_;
    return bless { _data => $row }, ref($self) || $self;
}

sub unblessed {
    my ($self) = @_;
    return { %{ $self->{_data} } };
}

our $AUTOLOAD;

sub AUTOLOAD {
    my $self = shift;

    my $method = $AUTOLOAD;
    $method =~ s/.*:://;
    return if $method eq 'DESTROY';

    croak( $method . ' is not a column on ' . $self->_table )
        unless $self->{_data} && exists $self->{_data}{$method};

    if (@_) {
        $self->{_data}{$method} = shift;
        return $self;
    }

    return $self->{_data}{$method};
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/model_base.t`
Expected: PASS (6 subtests)

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Model/Base.pm t/model_base.t
git commit -m "Rewrite Model::Base as a thin Mojo::Pg wrapper, replacing DBIx::Class/AUTOLOAD-over-DBIC"
```

---

## Task 5: Port `Model::Plugin`, `Model::PluginVersion` (renamed), `Model::User`

**Files:**
- Modify: `lib/KohaPluginStore/Model/Plugin.pm`
- Rename (via `git mv`) + Modify: `lib/KohaPluginStore/Model/Release.pm` → `lib/KohaPluginStore/Model/PluginVersion.pm`
- Modify: `lib/KohaPluginStore/Model/User.pm`
- Test: `t/model_plugin.t`, `t/model_user.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Model::Base` (Task 4).
- Produces: `KohaPluginStore::Model::Plugin` (table `plugins`, plus `releases()` returning an arrayref of `PluginVersion` objects), `KohaPluginStore::Model::PluginVersion` (table `plugin_versions`), `KohaPluginStore::Model::User` (table `users`, plus `check_password($username, $password)` and a `create` override that hashes the password) — all with the same public methods Controllers already call today.

- [ ] **Step 1: Write the failing test for Plugin/PluginVersion**

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

subtest 'plugin releases returns its versions' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new->create( { name => 'CoverFlow' } );

    KohaPluginStore::Model::PluginVersion->new->create(
        { plugin_id => $plugin->id, version => '2.5.7', tag_name => 'v2.5.7' }
    );
    KohaPluginStore::Model::PluginVersion->new->create(
        { plugin_id => $plugin->id, version => '2.5.8', tag_name => 'v2.5.8' }
    );

    my $versions = $plugin->releases;
    is( scalar @$versions, 2, 'both versions returned' );
    is( ( sort map { $_->version } @$versions )[0], '2.5.7', 'version accessor works on the related object' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/model_plugin.t`
Expected: FAIL — `KohaPluginStore::Model::PluginVersion` doesn't exist yet

- [ ] **Step 3: Rewrite `Model::Plugin.pm`**

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

    my @versions = KohaPluginStore::Model::PluginVersion->new->search( { plugin_id => $self->id } );
    return \@versions;
}

1;
```

- [ ] **Step 4: Rename and rewrite Release.pm to PluginVersion.pm**

```bash
git mv lib/KohaPluginStore/Model/Release.pm lib/KohaPluginStore/Model/PluginVersion.pm
```

Then replace its contents:

```perl
package KohaPluginStore::Model::PluginVersion;

use Modern::Perl;
use parent -norequire, 'KohaPluginStore::Model::Base';

sub _table {
    return 'plugin_versions';
}

sub _columns {
    return [qw(id plugin_id name tag_name version koha_min_version kpz_url date_released)];
}

1;
```

- [ ] **Step 5: Run test to verify it passes**

Run: `prove -l t/model_plugin.t`
Expected: PASS

- [ ] **Step 6: Write the failing test for User**

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db);

use KohaPluginStore::Model::User;

reset_db();

subtest 'create hashes the password' => sub {
    my $user = KohaPluginStore::Model::User->new->create(
        { username => 'admin', password => 'admin', email => 'admin@example.com' }
    );
    isnt( $user->password, 'admin', 'password is not stored in plain text' );
};

subtest 'check_password verifies correctly' => sub {
    KohaPluginStore::Model::User->new->create(
        { username => 'jdoe', password => 'secret123', email => 'jdoe@example.com' }
    );
    ok( KohaPluginStore::Model::User::check_password( 'jdoe', 'secret123' ), 'correct password verifies' );
    ok( !KohaPluginStore::Model::User::check_password( 'jdoe', 'wrongpassword' ), 'wrong password fails' );
    ok( !KohaPluginStore::Model::User::check_password( 'nosuchuser', 'anything' ), 'unknown user fails' );
};

subtest 'create requires a password' => sub {
    eval { KohaPluginStore::Model::User->new->create( { username => 'nopass', email => 'x@example.com' } ) };
    like( $@, qr/password is required/, 'raises without a password' );
};

done_testing();
```

- [ ] **Step 7: Run test to verify it fails**

Run: `prove -l t/model_user.t`
Expected: FAIL — old `Model::User.pm` still assumes a DBIx::Class-backed `Model::Base`

- [ ] **Step 8: Rewrite `Model::User.pm`**

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
    my ( $username, $password ) = @_;

    return undef unless $password;
    my $user = KohaPluginStore::Model::User->new->find( { username => $username } );

    return undef unless $user;
    return Passwords::password_verify( $password, $user->password );
}

sub create {
    my ( $self, $attrs ) = @_;

    Carp::croak('password is required') unless $attrs->{password};
    $attrs->{password} = Passwords::password_hash( $attrs->{password} );

    return $self->SUPER::create($attrs);
}

1;
```

(Dropped the old `use Data::Structure::Util qw( unbless );` import — it was unused.)

- [ ] **Step 9: Run test to verify it passes**

Run: `prove -l t/model_user.t`
Expected: PASS (3 subtests)

- [ ] **Step 10: Commit**

```bash
git add lib/KohaPluginStore/Model/Plugin.pm lib/KohaPluginStore/Model/PluginVersion.pm lib/KohaPluginStore/Model/User.pm t/model_plugin.t t/model_user.t
git commit -m "Port Plugin/PluginVersion/User models onto the new Mojo::Pg-backed Base"
```

---

## Task 6: Wire controllers and app startup to the new models

**Files:**
- Modify: `lib/KohaPluginStore.pm`
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm`
- Modify: `lib/KohaPluginStore/Controller/Releases.pm`
- Modify: `t/basic.t`
- Delete: `t/login.t`
- Create: `t/site.t`, `t/api_plugins.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Model::DB->pg`, `Model::Plugin`, `Model::PluginVersion`, `Model::User` (Tasks 3–5).
- Produces: a fully working app on Postgres — same routes, same templates, same behaviour as today.

- [ ] **Step 1: Update `KohaPluginStore.pm` startup**

Remove the unused `use Mojo::SQLite;` import and the old DB-init line; initialise the `Mojo::Pg` singleton from app config instead:

```perl
package KohaPluginStore;
use Mojo::Base 'Mojolicious', -signatures;

use KohaPluginStore::Model::User;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::DB;

has site_name => sub {
    my $app = shift;
    return $app->config->{site_name} || 'Koha Plugin Store';
};

sub startup ($self) {

    $self->plugin('Config');
    KohaPluginStore::Model::DB->pg( $self->config );

    $self->helper(
        logged_in_user => sub {
            my ( $c, $user ) = @_;
            $user ||= $c->stash->{user} || $c->session->{user};
            return unless $user;
            return KohaPluginStore::Model::User->new()->find( { username => $user->{username} } )
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

(Route list and the `#TODO`s are unchanged from today — this task only touches persistence wiring, not routing. The stray `/api/plugins` `#TODO` about OpenAPI is addressed by Task 7, not here.)

- [ ] **Step 2: Update `Controller::Plugins.pm`'s model references**

In `lib/KohaPluginStore/Controller/Plugins.pm`, add an explicit import and update both call sites that construct a release/version:

At the top of the file, alongside the existing `use KohaPluginStore::Model::Plugin;`, add:

```perl
use KohaPluginStore::Model::PluginVersion;
```

In `edit_form`, change:

```perl
my $releases = $plugin->releases;
```

— this line is unchanged (it already goes through `$plugin->releases`, which Task 5 already re-pointed at `PluginVersion`). The only literal call sites to fix are in `new_plugin_confirm` and `list_all`:

```perl
    my $new_release = KohaPluginStore::Model::PluginVersion->new()->create(
        {
            plugin_id        => $new_plugin->id,
            name             => $release_name,
            tag_name         => $release_tag_name,
            date_released    => $release_date_released,
            version          => $release_version,
            koha_min_version => $release_koha_min_version,
            kpz_url          => $release_kpz_url
        }
    );
```

and in `list_all`:

```perl
    my @releases =
        map { $_->unblessed } KohaPluginStore::Model::PluginVersion->new()->search(
            { plugin_id => $plugin->{id} }, { order_by => { -desc => 'date_released' } }
        );
```

(Every other line in this file is unchanged — the GitHub-fetch/download/unpack/metadata-parsing logic doesn't touch the persistence layer and is out of scope for this phase.)

- [ ] **Step 3: Update `Controller::Releases.pm`'s model references**

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

    my $new_release = KohaPluginStore::Model::PluginVersion->new()->create(
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

- [ ] **Step 4: Delete the stale login test**

`t/login.t` tests a login flow (`form input[name="user"]`, a `/protected` route, "Welcome sebastian") that has never matched this app — it predates the current login implementation and was already marked `#TODO: Redo this, its out of date` in the file itself.

```bash
git rm t/login.t
```

- [ ] **Step 5: Update `t/basic.t` to use the test DB helper**

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->get_ok('/')->status_is(200)->content_like(qr/Koha Plugin Store/i);

done_testing();
```

(The old assertion checked for "Mojolicious" in the body, which was only ever true because of the framework's default welcome page — the app's real home page renders the site name instead. `content_like(qr/Koha Plugin Store/i)` matches what `templates/site/index.html.ep` actually renders via `title`.)

- [ ] **Step 6: Write `t/site.t` — real login/register coverage**

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');

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

- [ ] **Step 7: Write `t/api_plugins.t` — discovery endpoint coverage**

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db);

use KohaPluginStore::Model::User;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $user = KohaPluginStore::Model::User->new->create(
    { username => 'seeder', password => 'seederpass', email => 'seeder@example.com' }
);
my $plugin = KohaPluginStore::Model::Plugin->new->create(
    { name => 'CoverFlow', description => 'A widget', user_id => $user->id }
);
KohaPluginStore::Model::PluginVersion->new->create(
    {
        plugin_id        => $plugin->id,
        version          => '2.5.7',
        koha_min_version => '19.05',
        date_released    => '2024-07-01T15:34:06Z',
    }
);

my $t = Test::Mojo->new('KohaPluginStore');

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

- [ ] **Step 8: Run the full test suite**

Run: `prove -l t/`
Expected: all files PASS (`basic.t`, `site.t`, `api_plugins.t`, `model_db.t`, `model_base.t`, `model_plugin.t`, `model_user.t`)

- [ ] **Step 9: Commit**

```bash
git add lib/KohaPluginStore.pm lib/KohaPluginStore/Controller/Plugins.pm lib/KohaPluginStore/Controller/Releases.pm t/basic.t t/site.t t/api_plugins.t
git rm t/login.t
git commit -m "Wire controllers and app startup to the Postgres-backed models"
```

---

## Task 7: Minimal OpenAPI scaffold

**Files:**
- Create: `lib/KohaPluginStore/OpenAPI/spec.yaml`
- Create: `lib/KohaPluginStore/Controller/Api.pm`
- Modify: `lib/KohaPluginStore.pm`
- Test: `t/openapi_ping.t`

**Interfaces:**
- Produces: `GET /api/v1/ping` → `{"status":"ok"}`, validated by `Mojolicious::Plugin::OpenAPI` against `spec.yaml`. This is the seed of the "contract-first" API work in Phase 6 — not the real discovery API yet.

- [ ] **Step 1: Write the failing test**

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB;

my $t = Test::Mojo->new('KohaPluginStore');

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

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/openapi_ping.t`
Expected: FAIL — 404 on the GET (route doesn't exist yet)

- [ ] **Step 3: Add `Mojolicious::Plugin::OpenAPI` to cpanfile**

In `cpanfile`, add:

```
requires 'Mojolicious::Plugin::OpenAPI';
```

Run: `cpanm --installdeps .`

- [ ] **Step 4: Write the OpenAPI spec**

```yaml
openapi: 3.0.1
info:
  title: Koha Plugin Store API
  version: "1"
x-mojo-controller: KohaPluginStore::Controller::Api
paths:
  /ping:
    get:
      operationId: ping
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
```

- [ ] **Step 5: Write the controller**

```perl
package KohaPluginStore::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub ping ($c) {
    return $c->render( openapi => { status => 'ok' } );
}

1;
```

- [ ] **Step 6: Register the plugin in `startup()`**

In `lib/KohaPluginStore.pm`, add this line right after `$self->_add_routes_authorization();`:

```perl
    $self->plugin( 'OpenAPI', {
        url   => $self->home->child(qw(lib KohaPluginStore OpenAPI spec.yaml)),
        route => $self->routes->any('/api/v1'),
    } );
```

- [ ] **Step 7: Run test to verify it passes**

Run: `prove -l t/openapi_ping.t`
Expected: PASS (2 subtests)

- [ ] **Step 8: Run the full suite once more to confirm no regressions**

Run: `prove -l t/`
Expected: all PASS

- [ ] **Step 9: Commit**

```bash
git add lib/KohaPluginStore/OpenAPI/spec.yaml lib/KohaPluginStore/Controller/Api.pm lib/KohaPluginStore.pm cpanfile t/openapi_ping.t
git commit -m "Add minimal OpenAPI scaffold (GET /api/v1/ping)"
```

---

## Task 8: Rewrite seed script, delete obsolete DBIx::Class/SQLite files

**Files:**
- Modify: `lib/KohaPluginStore/Command/reset_test_data.pl`
- Delete: `lib/KohaPluginStore/Schema.pm`
- Delete: `lib/KohaPluginStore/Schema/Result/Plugin.pm`
- Delete: `lib/KohaPluginStore/Schema/Result/Release.pm`
- Delete: `lib/KohaPluginStore/Schema/Result/User.pm`
- Delete: `lib/KohaPluginStore/Command/create_db_schema.pl`
- Delete: `lib/KohaPluginStore/Command/make_dbic_schema_files.pl`
- Delete: `lib/KohaPluginStore/Command/test_queries.pl`

**Interfaces:**
- Produces: `perl lib/KohaPluginStore/Command/reset_test_data.pl` — truncates and reseeds `users`/`plugins`/`plugin_versions` on Postgres, same demo data as today.

- [ ] **Step 1: Rewrite `reset_test_data.pl`**

Same demo data as today (two users, four plugins, one release each — the current file has a second, commented-out CoverFlow release that was never active; it stays excluded here too), ported onto the new models:

```perl
#!/usr/bin/env perl
use Modern::Perl;
use Mojo::File qw(curfile);

use lib curfile->dirname->sibling('..')->to_string;

use KohaPluginStore::Model::DB;
use KohaPluginStore::Model::User;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

my $config_file = curfile->dirname->sibling('..')->sibling('koha_plugin_store.conf');
my $config = do "$config_file" or die "Could not load $config_file: $@$!";

KohaPluginStore::Model::DB->pg($config);
KohaPluginStore::Model::DB->pg->db->query(
    'TRUNCATE plugin_versions, plugins, users RESTART IDENTITY CASCADE'
);

# Users data:
# admin: admin
# John: Doe
my $admin = KohaPluginStore::Model::User->new->create(
    { username => 'admin', password => 'admin', email => 'admin@www.com' }
);
KohaPluginStore::Model::User->new->create(
    { username => 'John', password => 'Doe', email => 'john@doe.com' }
);

my $coverflow = KohaPluginStore::Model::Plugin->new->create(
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
KohaPluginStore::Model::PluginVersion->new->create(
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

my $ill_actions = KohaPluginStore::Model::Plugin->new->create(
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
KohaPluginStore::Model::PluginVersion->new->create(
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

my $pdf_to_cover = KohaPluginStore::Model::Plugin->new->create(
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
KohaPluginStore::Model::PluginVersion->new->create(
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

my $lms_event_management = KohaPluginStore::Model::Plugin->new->create(
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
KohaPluginStore::Model::PluginVersion->new->create(
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
```

- [ ] **Step 2: Delete the obsolete DBIx::Class and SQLite-era files**

```bash
git rm lib/KohaPluginStore/Schema.pm
git rm -r lib/KohaPluginStore/Schema
git rm lib/KohaPluginStore/Command/create_db_schema.pl
git rm lib/KohaPluginStore/Command/make_dbic_schema_files.pl
git rm lib/KohaPluginStore/Command/test_queries.pl
```

- [ ] **Step 3: Run it and verify**

Run: `perl lib/KohaPluginStore/Command/reset_test_data.pl`
Expected: `Test data reset.`

Run: `docker compose exec postgres psql -U koha_plugin_store -c 'SELECT count(*) FROM plugins;'`
Expected: `4`

- [ ] **Step 4: Run the full test suite once more**

Run: `prove -l t/`
Expected: all PASS (deleting the Schema/Command files doesn't touch anything the tests import)

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Command/reset_test_data.pl
git add -u
git commit -m "Port reset_test_data.pl to Postgres; remove obsolete DBIx::Class/SQLite files"
```

---

## Task 9: Update docs

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- None — documentation only.

- [ ] **Step 1: Update `README.md`'s Backend section**

Replace the "Notes" and "Commands" bullets under `## Backend` with:

```markdown
- Notes

  - A `koha_plugin_store.conf` file is required. Follow the example from `koha_plugin_store.conf.example`
    (now also holds `pg_dsn`, the Postgres connection string).
  - The `kpz_packages` directory is used to store `.kpz` files download from github.
  - To install cpan dependencies, run `cpanm --installdeps .` at the project
    root dir.
  - Local Postgres runs via `docker compose up -d postgres` (see `docker-compose.yml`).

- Commands
  - Start local Postgres: `docker compose up -d postgres`
  - Apply migrations: `perl lib/KohaPluginStore/Command/migrate.pl`
  - Reset test data: `perl lib/KohaPluginStore/Command/reset_test_data.pl`
```

(Remove the old `create_db_schema.pl` and `make_dbic_schema_files.pl` bullets — both scripts are gone.)

Also update `koha_plugin_store.conf.example`:

```perl
{
  # Github user access token
  github_user_access_token => "YOUR_TOKEN_HERE",

  # Postgres connection string
  pg_dsn => "postgresql://koha_plugin_store:koha_plugin_store@127.0.0.1:55432/koha_plugin_store",
};
```

- [ ] **Step 2: Update `CLAUDE.md`**

In the "Commands" section, replace the SQLite-era commands with:

```markdown
docker compose up -d postgres                          # start local Postgres
cpanm --installdeps .                                  # install CPAN dependencies (see cpanfile)
perl lib/KohaPluginStore/Command/migrate.pl             # apply Postgres migrations
perl lib/KohaPluginStore/Command/reset_test_data.pl     # wipe and reseed demo users/plugins/releases
morbo script/koha_plugin_store                          # run dev server with auto-reload
prove -l t/basic.t                                      # run a single test
prove -l t/                                             # run all tests
```

In the "Data layer" architecture section, replace the DBIx::Class/SQLite description with:

```markdown
### Data layer — a thin Mojo::Pg CRUD wrapper

- `KohaPluginStore::Model::DB` holds a single `Mojo::Pg` connection singleton, initialised
  once at app startup from `koha_plugin_store.conf`'s `pg_dsn`.
- `KohaPluginStore::Model::Base` — base class for `Model::{Plugin,PluginVersion,User}`.
  Each subclass declares `_table` (the Postgres table name) and `_columns` (used for
  `INSERT ... RETURNING`). `create`/`find`/`search` are built on `Mojo::Pg::Database`'s
  `insert`/`select` query builder. Column accessors (`->id`, `->name`, etc.) are still
  synthesized via `AUTOLOAD`, but now read/write directly against the fetched row's hash
  rather than reflecting a DBIx::Class result object's columns.
- Migrations live in `migrations/koha_plugin_store.sql` (Mojo::Pg's built-in `-- 1 up`/
  `-- 1 down` format), applied via `lib/KohaPluginStore/Command/migrate.pl`.
- `plugin_versions` is the Postgres name for what used to be SQLite's `releases` table;
  the Perl class is `KohaPluginStore::Model::PluginVersion` (was `Model::Release`).
```

Remove the note about `DO NOT MODIFY THE FIRST PART OF THIS FILE` DBIx::Class Schema/Result classes — they no longer exist.

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md koha_plugin_store.conf.example
git commit -m "Update docs for the Postgres/Mojo::Pg foundation"
```
