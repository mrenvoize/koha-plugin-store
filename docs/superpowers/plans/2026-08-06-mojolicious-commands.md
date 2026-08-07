# Convert Command Scripts to Mojolicious::Command Classes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two standalone `perl lib/KohaPluginStore/Command/*.pl` scripts with proper `Mojolicious::Command` classes, invoked via `script/koha_plugin_store <command>`, per the [Mojolicious Cookbook's "Adding commands to Mojolicious"](https://metacpan.org/dist/Mojolicious/view/lib/Mojolicious/Guides/Cookbook.pod#Adding-commands-to-Mojolicious). Also move the migration SQL onto [Mojo::Pg::Migrations](https://metacpan.org/pod/Mojo::Pg::Migrations)'s standard `from_data` scheme (embedded in a `__DATA__` section) instead of an external `.sql` file loaded via `from_file`.

**Architecture:** Per the Cookbook, app-specific command namespaces are **not** auto-discovered — the app must explicitly register them with one line in `startup()`: `push @{$self->commands->namespaces}, 'KohaPluginStore::Command';`. This is the *only* wiring change needed anywhere outside the two command files themselves — do not create a custom `Mojolicious::Commands` subclass, do not override the app's `commands` attribute, do not touch `script/koha_plugin_store`, and do not set `MOJO_HOME` anywhere. If any of those seem necessary while implementing this, stop — it means the one-line registration wasn't done correctly, not that heavier machinery is needed.

Each command becomes a package inheriting `Mojolicious::Command` with a `run` method. Because `script/koha_plugin_store <command>` boots the full app first (running `startup()`, which already calls `$self->plugin('Config')` and `KohaPluginStore::Model::DB->pg($self->config)`), commands get a fully-configured `Model::DB->pg` singleton for free — eliminating both scripts' bespoke config-loading. `migrate` also moves its SQL into its own `__DATA__` section and calls `$pg->migrations->from_data(__PACKAGE__)->migrate`, per Mojo::Pg's documented pattern — this removes the `migrations/` directory and the `Mojo::File` `dirname->dirname->dirname->dirname` path navigation entirely, which has already caused two separate bugs earlier in this project's history (once in `migrate.pl` itself, once in `reset_test_data.pl`).

**Tech Stack:** `Mojolicious::Command` (core Mojolicious), `Mojo::Pg::Migrations`'s `from_data`, `-signatures`.

## Global Constraints

- The **only** files this plan touches are: `lib/KohaPluginStore.pm` (one line added to `startup()`), `lib/KohaPluginStore/Command/migrate.pm` (new, replaces `.pl`), `lib/KohaPluginStore/Command/reset_test_data.pm` (new, replaces `.pl`), `migrations/koha_plugin_store.sql` (deleted — its content moves into `migrate.pm`'s `__DATA__` section), `README.md`, `CLAUDE.md`. Nothing else. If something else appears to need a change to make this work, STOP and report BLOCKED/NEEDS_CONTEXT rather than improvising — a previous attempt at this exact plan went off-script this way (a custom `Mojolicious::Commands` subclass, a `MOJO_HOME` environment variable hack, and an unrelated `Dockerfile` change) and was reverted entirely.
- Commands must be invoked as `script/koha_plugin_store migrate` and `script/koha_plugin_store reset_test_data` — no other invocation syntax.
- Seed data in `reset_test_data` must remain byte-identical to what's there today (2 users, 4 plugins, 4 versions, same field values) — this is a mechanical conversion, not a chance to change behaviour.
- Migration SQL content (the `CREATE TABLE`/`DROP TABLE` statements) must be byte-identical to what's in `migrations/koha_plugin_store.sql` today — only *where* it lives changes, not what it says.
- Every place these commands or the migrations file are documented (README.md's two sections, CLAUDE.md) must be updated — a stale reference is a real defect here, not a nitpick, given this project's history of docs drifting from reality.
- `t/lib/TestDB.pm` does not go through the app's command system or run migrations at all (it truncates already-migrated tables directly via `KohaPluginStore::Model::DB->pg`) and is out of scope for this plan — do not touch it.

---

## Task 1: Register the command namespace, convert both commands, move migrations to `from_data`

**Files:**
- Modify: `lib/KohaPluginStore.pm`
- Delete: `lib/KohaPluginStore/Command/migrate.pl`
- Create: `lib/KohaPluginStore/Command/migrate.pm`
- Delete: `lib/KohaPluginStore/Command/reset_test_data.pl`
- Create: `lib/KohaPluginStore/Command/reset_test_data.pm`
- Delete: `migrations/koha_plugin_store.sql` (and the now-empty `migrations/` directory)

**Interfaces:**
- Produces: `script/koha_plugin_store migrate` and `script/koha_plugin_store reset_test_data`.

- [ ] **Step 1: Register the command namespace**

In `lib/KohaPluginStore.pm`, inside `startup()`, add this line (the Cookbook's own recommended pattern — this is the only change needed anywhere for command auto-discovery to work):

```perl
sub startup ($self) {

    $self->plugin('Config');
    KohaPluginStore::Model::DB->pg( $self->config );

    push @{ $self->commands->namespaces }, 'KohaPluginStore::Command';

    $self->helper(
        ...
```

(Add it right after the `Model::DB->pg(...)` line, before the rest of `startup()` — exact position among the other early-`startup()` lines doesn't matter, just don't reorder anything else in that method.)

- [ ] **Step 2: Write `migrate.pm` with embedded migrations**

```perl
package KohaPluginStore::Command::migrate;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::Model::DB;

has description => 'Apply Postgres migrations';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $pg = KohaPluginStore::Model::DB->pg;
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

(The `@@ migrations` marker matches `Mojo::Pg::Migrations`' default `name` attribute — no need to call `->name(...)` explicitly. `from_data(__PACKAGE__)` is explicit about which package's `__DATA__` section to read, rather than relying on `from_data`'s no-args `caller`-detection default.)

- [ ] **Step 3: Delete the old migrate.pl and the migrations directory**

```bash
git rm lib/KohaPluginStore/Command/migrate.pl
git rm migrations/koha_plugin_store.sql
rmdir migrations
```

- [ ] **Step 4: Verify migrate works**

Ensure `koha_plugin_store.conf` exists (copy from `koha_plugin_store.conf.example` if not) and Postgres is running (`docker compose up -d postgres`). If tables from a previous run already exist, drop them first (`docker compose exec postgres psql -U koha_plugin_store -c 'DROP TABLE IF EXISTS plugin_versions, plugins, users;'`) so this is a clean first-migration test.

Run: `script/koha_plugin_store migrate`
Expected: `Migrated to version 1`

Run: `docker compose exec postgres psql -U koha_plugin_store -c '\dt'`
Expected: lists `users`, `plugins`, `plugin_versions`.

Run: `script/koha_plugin_store help`
Expected: `migrate` and `reset_test_data` (once Step 8 adds it) appear in the list of available commands, alongside Mojolicious's built-ins.

Run: `script/koha_plugin_store migrate --help`
Expected: shows the `Usage: APPLICATION migrate` synopsis text.

- [ ] **Step 5: Write `reset_test_data.pm`**

Same seed data as today's `reset_test_data.pl`, ported onto the `run` method — `Model::DB->pg` is already initialized by the app's own `startup()` by the time `run` executes, so there's no config-loading code needed here at all:

```perl
package KohaPluginStore::Command::reset_test_data;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::Model::DB;
use KohaPluginStore::Model::User;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

has description => 'Wipe and reseed demo users/plugins/releases';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
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
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::reset_test_data - Wipe and reseed demo data

=head1 SYNOPSIS

  Usage: APPLICATION reset_test_data

=cut
```

- [ ] **Step 6: Delete the old reset_test_data.pl**

```bash
git rm lib/KohaPluginStore/Command/reset_test_data.pl
```

- [ ] **Step 7: Verify reset_test_data works**

Run: `script/koha_plugin_store reset_test_data`
Expected: `Test data reset.`

Run: `docker compose exec postgres psql -U koha_plugin_store -c 'SELECT count(*) FROM plugins;'`
Expected: `4`

- [ ] **Step 8: Run the full test suite**

Run: `prove -l t/`
Expected: all PASS

- [ ] **Step 9: Verify the Docker flow still works with the new invocation**

Run: `docker compose up -d --build` (rebuild picks up the new command files)
Run: `docker compose exec app script/koha_plugin_store migrate`
Expected: `Migrated to version 1`
Run: `docker compose exec app script/koha_plugin_store reset_test_data`
Expected: `Test data reset.`

- [ ] **Step 10: Commit**

```bash
git add lib/KohaPluginStore.pm lib/KohaPluginStore/Command/migrate.pm lib/KohaPluginStore/Command/reset_test_data.pm
git add -u
git commit -m "Convert migrate/reset_test_data scripts to Mojolicious::Command classes

Also moves migrations onto Mojo::Pg::Migrations' standard from_data scheme
(embedded in migrate.pm's __DATA__ section) instead of an external .sql
file loaded via from_file."
```

---

## Task 2: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- None — documentation only.

- [ ] **Step 1: Update README.md's Backend "Commands" section**

Replace:

```markdown
- Commands
  - Start local Postgres: `docker compose up -d postgres`
  - Apply migrations: `perl lib/KohaPluginStore/Command/migrate.pl`
  - Reset test data: `perl lib/KohaPluginStore/Command/reset_test_data.pl`
```

with:

```markdown
- Commands
  - Start local Postgres: `docker compose up -d postgres`
  - Apply migrations: `script/koha_plugin_store migrate`
  - Reset test data: `script/koha_plugin_store reset_test_data`
```

- [ ] **Step 2: Update README.md's "Docker development" section**

Replace the `docker compose exec app perl lib/KohaPluginStore/Command/...` lines with
`docker compose exec app script/koha_plugin_store ...`:

```markdown
### Docker development

No local Perl or Postgres install needed:

1. `cp koha_plugin_store.conf.docker.example koha_plugin_store.conf` (edit in your
   `github_user_access_token` if you need GitHub-backed features)
2. `docker compose up -d --build`
3. `docker compose exec app script/koha_plugin_store migrate` (first run only)
4. `docker compose exec app script/koha_plugin_store reset_test_data` (optional demo data)
5. Visit http://127.0.0.1:3000

Edits to the repo on your host are picked up automatically (`morbo` hot-reloads inside the
container) — no rebuild needed unless you change `cpanfile` or the `Dockerfile` itself.

This is separate from `koha_plugin_store.conf.example`, used for running directly on the
host — the two files point at Postgres differently (`postgres` as the hostname inside
Docker's network vs. `127.0.0.1:55432` on the host).
```

- [ ] **Step 3: Update CLAUDE.md**

Read the current CLAUDE.md as it exists in this worktree (don't assume its exact wording —
it was written before this change) and:

- Replace the `perl lib/KohaPluginStore/Command/migrate.pl` / `perl
  lib/KohaPluginStore/Command/reset_test_data.pl` command lines with `script/koha_plugin_store
  migrate` / `script/koha_plugin_store reset_test_data`.
- Update the "Data layer" architecture section: describe `migrate` and `reset_test_data` as
  `Mojolicious::Command` classes under `KohaPluginStore::Command::*` (registered via
  `push @{$self->commands->namespaces}, 'KohaPluginStore::Command'` in `startup()`), not
  standalone scripts. Update the migrations description: they live in `migrate.pm`'s own
  `__DATA__` section (Mojo::Pg's `from_data` scheme), not a separate `migrations/*.sql` file.

- [ ] **Step 4: Grep for any other stale references**

Run: `grep -rn "Command/migrate.pl\|Command/reset_test_data.pl\|migrations/koha_plugin_store.sql" --include='*.md' .`
Expected: no output. If anything is found, fix it too.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "Update docs for the Mojolicious::Command conversion and embedded migrations"
```
