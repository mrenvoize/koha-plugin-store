# Plugin Submission Pipeline Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the synchronous "fetch latest release → download → parse → confirm →
insert" plugin submission pipeline with an async one: the developer picks a repo and a
specific tag, rows are created immediately (`status = 'submitted'`), and a Minion
background job downloads, extracts, parses, digests, and records author/contributor
metadata — updating `status` as it goes, visible on a new public plugin detail page.

**Architecture:** Two Mojolicious controllers (`Plugins`, `Releases`) keep their existing
routes but get lighter — they validate ownership, fetch release metadata (cheap GitHub API
calls), create DB rows, and enqueue one Minion job per submission. All the slow/fallible
work (download, unzip, regex-parse `$metadata`, fetch contributors, compute a SHA-256
digest) moves into a single new `process_plugin_version` Minion task. A new public route,
`GET /plugins/:slug`, shows live status.

**Tech Stack:** Mojolicious, `Mojo::Pg`, `Minion` + `Minion::Backend::Pg` (bundled in the
same CPAN distribution), `Archive::Zip`, `Digest::SHA`, `Test::Mojo`.

## Global Constraints

- `github_app_token` (replacing `github_user_access_token`) must be a fine-grained GitHub
  PAT scoped to "Public Repositories (read-only)" access only — documented in
  `koha_plugin_store.conf.example`/`.docker.example`, not enforced in code.
- `process_plugin_version` jobs are enqueued with `{ attempts => 3 }` — Minion's default
  backoff handles retries for infrastructure failures.
- Slug collision retry is bounded at 10 attempts.
- `fetch_releases` returns a fixed page of the 10 most recent releases — no pagination.
- No permanent local `.kpz` cache — the job always downloads to a `File::Temp` tempdir
  (`CLEANUP => 1`), never to a tracked/gitignored project directory.
- No §6 required-checks/levels pipeline, no Ed25519 signing, no notification/email
  delivery, no OpenAPI-first rewrite of the submission UI — all explicitly out of scope
  (see the design doc's Non-goals).
- Follow existing code conventions exactly: `GitHub.pm` functions are module-level subs,
  never imported (`use KohaPluginStore::GitHub;` then fully-qualified calls), so tests can
  override them via typeglob assignment — the same pattern already used for
  `fetch_public_repos` and reused throughout this plan.
- Tests that touch Minion must re-register the plugin against the test database after
  swapping `pg` (see Task 1) — `$t->app->pg(test_pg())` alone does not repoint an
  already-registered Minion backend.

---

### Task 1: Add Minion and register it against the app's Postgres connection

**Files:**
- Modify: `cpanfile`
- Modify: `lib/KohaPluginStore.pm`
- Test: `t/minion.t` (new)

**Interfaces:**
- Produces: the `minion` helper (`$c->minion` / `$app->minion`), available to every later
  task.

- [ ] **Step 1: Write a failing test**

Create `t/minion.t`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Developer;

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );
$t->app->plugin( Minion => { Pg => test_pg() } );

subtest 'the minion helper is registered and can run a trivial job' => sub {
    $t->app->minion->add_task(
        test_task => sub {
            my $job = shift;
            KohaPluginStore::Model::Developer->new( pg => $job->app->pg )->create(
                { oauth_provider_key => 'test', provider_user_id => 'minion-smoke-test', username => 'minion-smoke-test' }
            );
        }
    );
    $t->app->minion->enqueue('test_task');
    $t->app->minion->perform_jobs;

    my $created = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { provider_user_id => 'minion-smoke-test' }
    );
    ok( $created, 'the enqueued job actually ran and wrote to the database' );
};

done_testing();
```

(`perform_jobs` forks a real child process per job — `Minion::Job::perform` calls `fork`
internally, unlike `perform_jobs_in_foreground`, which runs in-process. A job's writes to
the shared Postgres are visible back in the test process once `perform_jobs` returns; an
in-memory Perl variable captured by the job's closure is not, since it lives in the
child's separate address space. Every later task in this plan checks Minion job outcomes
via the database for exactly this reason — this smoke test does the same, deliberately, so
it's representative of the pattern the rest of the plan relies on.)

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/minion.t
```
Expected: FAIL — `Can't locate object method "plugin" ... Minion` or similar, since the
`Minion` plugin isn't installed/registered yet.

- [ ] **Step 3: Add the dependency**

In `cpanfile`, add (anywhere in the existing list — alphabetical position doesn't matter,
this file isn't sorted):

```perl
requires 'Minion';
```

`Minion::Backend::Pg` is bundled inside the `Minion` distribution itself — no separate
`requires` line needed.

```bash
cpanm --installdeps .
```

- [ ] **Step 4: Register the plugin in `startup()`**

In `lib/KohaPluginStore.pm`, change:
```perl
    $self->plugin( OAuth2 => \%oauth2_providers );

    push @{ $self->commands->namespaces }, 'KohaPluginStore::Command';
```
to:
```perl
    $self->plugin( OAuth2 => \%oauth2_providers );

    $self->plugin( Minion => { Pg => $self->pg } );

    push @{ $self->commands->namespaces }, 'KohaPluginStore::Command';
```

- [ ] **Step 5: Run `t/minion.t` again to verify it passes**

```bash
prove -l t/minion.t
```
Expected: PASS.

- [ ] **Step 6: Run the full suite to confirm nothing else broke**

```bash
prove -l t/
```
Expected: PASS (all files) — this task changes no existing behavior.

- [ ] **Step 7: Commit**

```bash
git add cpanfile lib/KohaPluginStore.pm t/minion.t
git commit -m "Add Minion, registered against the app's Postgres connection"
```

---

### Task 2: Rename `github_user_access_token` to `github_app_token`

**Files:**
- Modify: `koha_plugin_store.conf.example`
- Modify: `koha_plugin_store.conf.docker.example`
- Modify: `koha_plugin_store.conf` (your own local, gitignored copy — not committed)
- Modify: `CLAUDE.md`

**Interfaces:**
- Produces: the config key `github_app_token`, read via `$c->app->plugin('Config')` (the
  existing idiom already used throughout `Controller::Plugins`) by Tasks 6, 7, and 8.

No test for this task — it's a rename of a config key that nothing yet reads (the old key
`github_user_access_token` is read by `Controller::Plugins::_get_latest_release_from_github`
and `_get_releases_from_github`, both of which Tasks 7 and 8 delete outright, so there's no
overlap to keep working during the transition).

- [ ] **Step 1: Update `koha_plugin_store.conf.example`**

Change:
```perl
  # Github user access token
  github_user_access_token => "YOUR_TOKEN_HERE",
```
to:
```perl
  # GitHub token used for the store's own background API calls (fetching release info,
  # downloading .kpz assets, fetching contributors) -- NOT the developer's own login
  # token. Must be a fine-grained personal access token scoped to "Public Repositories
  # (read-only)" access only: https://github.com/settings/personal-access-tokens/new
  # This constrained scope is deliberate -- it doubles as confirmation that an anonymous
  # Koha library (with no GitHub credentials at all) will be able to fetch the same URLs.
  github_app_token => "YOUR_TOKEN_HERE",
```

- [ ] **Step 2: Update `koha_plugin_store.conf.docker.example`** with the same change.

- [ ] **Step 3: Update your own local `koha_plugin_store.conf`** (gitignored, not
  committed) the same way, so the app and test suite keep working locally through the
  rest of this plan.

- [ ] **Step 4: Update `CLAUDE.md`**

In the "Commands" section, change:
```
It holds
`github_user_access_token` (for GitHub API calls), `pg_dsn` (Postgres connection
string), and `oauth_providers`
```
to:
```
It holds
`github_app_token` (a fine-grained, public-repos-read-only PAT for the store's own
background GitHub API calls), `pg_dsn` (Postgres connection string), and
`oauth_providers`
```

- [ ] **Step 5: Commit**

```bash
git add koha_plugin_store.conf.example koha_plugin_store.conf.docker.example CLAUDE.md
git commit -m "Rename github_user_access_token to github_app_token"
```

(Your local `koha_plugin_store.conf` is gitignored and won't be part of this commit.)

---

### Task 3: Migration version 3 — schema changes and model updates

**Files:**
- Modify: `lib/KohaPluginStore/Command/migrate.pm`
- Modify: `lib/KohaPluginStore/Model/Plugin.pm`
- Modify: `lib/KohaPluginStore/Model/PluginVersion.pm`
- Create: `lib/KohaPluginStore/Model/PluginContributor.pm`
- Modify: `t/lib/TestDB.pm`
- Test: `t/model_plugin_contributor.t` (new)

**Interfaces:**
- Produces: `plugins.slug`, `plugins.documentation_url`; `plugin_versions.status`,
  `.error_message`, `.content_digest`, `.author_username`, `.author_avatar_url`; the
  `plugin_contributors` table and `KohaPluginStore::Model::PluginContributor` (same
  `Model::Base`-derived shape as `Plugin`/`PluginVersion`: `_table`, `_columns`).

- [ ] **Step 1: Add the migration**

In `lib/KohaPluginStore/Command/migrate.pm`, after the existing `-- 2 down` block (the
file's last lines), append:

```sql

-- 3 up
ALTER TABLE plugins ADD COLUMN slug TEXT UNIQUE;
ALTER TABLE plugins ADD COLUMN documentation_url TEXT;

ALTER TABLE plugin_versions ADD COLUMN status TEXT NOT NULL DEFAULT 'submitted';
ALTER TABLE plugin_versions ADD COLUMN error_message TEXT;
ALTER TABLE plugin_versions ADD COLUMN content_digest TEXT;
ALTER TABLE plugin_versions ADD COLUMN author_username TEXT;
ALTER TABLE plugin_versions ADD COLUMN author_avatar_url TEXT;
ALTER TABLE plugin_versions ADD CONSTRAINT plugin_versions_plugin_id_tag_name_key
    UNIQUE (plugin_id, tag_name);

CREATE TABLE plugin_contributors (
    id                  SERIAL PRIMARY KEY,
    plugin_id           INTEGER REFERENCES plugins(id) ON DELETE CASCADE,
    github_username     TEXT NOT NULL,
    avatar_url          TEXT,
    contributions_count INTEGER,
    fetched_at          TIMESTAMPTZ DEFAULT now(),
    UNIQUE (plugin_id, github_username)
);

-- 3 down
DROP TABLE plugin_contributors;

ALTER TABLE plugin_versions DROP CONSTRAINT plugin_versions_plugin_id_tag_name_key;
ALTER TABLE plugin_versions DROP COLUMN author_avatar_url;
ALTER TABLE plugin_versions DROP COLUMN author_username;
ALTER TABLE plugin_versions DROP COLUMN content_digest;
ALTER TABLE plugin_versions DROP COLUMN error_message;
ALTER TABLE plugin_versions DROP COLUMN status;

ALTER TABLE plugins DROP COLUMN documentation_url;
ALTER TABLE plugins DROP COLUMN slug;
```

- [ ] **Step 2: Apply it to your local database**

```bash
perl script/koha_plugin_store migrate
```
Expected output: `Migrated to version 3`.

Also apply it directly to the shared test database (the one `t/lib/TestDB.pm` points at),
since `prove` never runs migrations itself — only application code does:

```bash
perl -Ilib -MMojo::Pg -MKohaPluginStore::Command::migrate -e '
my $pg = Mojo::Pg->new("postgresql://koha_plugin_store:koha_plugin_store\@127.0.0.1:55432/koha_plugin_store");
$pg->migrations->from_data("KohaPluginStore::Command::migrate")->migrate;
print "Migrated to version " . $pg->migrations->active . "\n";
'
```
Expected: `Migrated to version 3`. (If your test Postgres is only reachable via a
docker-compose service hostname rather than `127.0.0.1:55432`, adjust the DSN to match —
see `t/lib/TestDB.pm`'s own `$DSN` default for the convention this project uses.)

- [ ] **Step 3: Update `Model::Plugin`'s columns**

In `lib/KohaPluginStore/Model/Plugin.pm`, change:
```perl
sub _columns {
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp)];
}
```
to:
```perl
sub _columns {
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp slug documentation_url)];
}
```

- [ ] **Step 4: Update `Model::PluginVersion`'s columns**

In `lib/KohaPluginStore/Model/PluginVersion.pm`, change:
```perl
sub _columns {
    return [qw(id plugin_id name tag_name version koha_min_version kpz_url date_released)];
}
```
to:
```perl
sub _columns {
    return [qw(id plugin_id name tag_name version koha_min_version kpz_url date_released status error_message content_digest author_username author_avatar_url)];
}
```

- [ ] **Step 5: Write a failing test for the new model**

Create `t/model_plugin_contributor.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginContributor;

reset_db();

subtest 'create and find a contributor' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'Widget' } );

    my $contributor = KohaPluginStore::Model::PluginContributor->new( pg => test_pg() )->create(
        {
            plugin_id           => $plugin->id,
            github_username     => 'octocat',
            avatar_url          => 'https://example.com/a.png',
            contributions_count => 42,
        }
    );

    ok( $contributor->id, 'id was assigned' );
    is( $contributor->github_username, 'octocat', 'github_username accessor reads back' );

    my $found = KohaPluginStore::Model::PluginContributor->new( pg => test_pg() )->find(
        { plugin_id => $plugin->id, github_username => 'octocat' }
    );
    is( $found->contributions_count, 42, 'found the right row' );
};

done_testing();
```

- [ ] **Step 6: Run it to verify it fails**

```bash
prove -l t/model_plugin_contributor.t
```
Expected: FAIL — `Can't locate KohaPluginStore/Model/PluginContributor.pm`.

- [ ] **Step 7: Create `KohaPluginStore::Model::PluginContributor`**

Create `lib/KohaPluginStore/Model/PluginContributor.pm`:

```perl
package KohaPluginStore::Model::PluginContributor;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

sub _table {
    return 'plugin_contributors';
}

sub _columns {
    return [qw(id plugin_id github_username avatar_url contributions_count fetched_at)];
}

1;
```

- [ ] **Step 8: Run `t/model_plugin_contributor.t` again to verify it passes**

```bash
prove -l t/model_plugin_contributor.t
```
Expected: PASS.

- [ ] **Step 9: Update `t/lib/TestDB.pm` to truncate the new table**

Change:
```perl
sub reset_db {
    $PG->db->query(
        'TRUNCATE plugin_versions, plugins, developers RESTART IDENTITY CASCADE'
    );
}
```
to:
```perl
sub reset_db {
    $PG->db->query(
        'TRUNCATE plugin_versions, plugins, developers, plugin_contributors RESTART IDENTITY CASCADE'
    );
}
```

- [ ] **Step 10: Run the full suite**

```bash
prove -l t/
```
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add lib/KohaPluginStore/Command/migrate.pm lib/KohaPluginStore/Model/Plugin.pm \
    lib/KohaPluginStore/Model/PluginVersion.pm lib/KohaPluginStore/Model/PluginContributor.pm \
    t/lib/TestDB.pm t/model_plugin_contributor.t
git commit -m "Add migration 3: slug, status, digest, author, and contributors"
```

---

### Task 4: `Model::Plugin::create_with_unique_slug`

**Files:**
- Modify: `lib/KohaPluginStore/Model/Plugin.pm`
- Test: `t/model_plugin.t`

**Interfaces:**
- Produces: `KohaPluginStore::Model::Plugin->new(pg => $pg)->create_with_unique_slug($slug_source, \%attrs)`
  → a created `Plugin` object with a unique `slug` derived from `$slug_source`, or dies
  after 10 failed attempts. `%attrs` is passed through to `create` unchanged, with `slug`
  added.

- [ ] **Step 1: Write failing tests**

Append to `t/model_plugin.t`, after the existing `subtest`:

```perl
subtest 'create_with_unique_slug normalizes the source string' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'Koha_Plugin!! Coverflow', { repo_url => 'https://github.com/a/coverflow' }
    );
    is( $plugin->slug, 'koha-plugin-coverflow', 'non-alphanumeric runs collapse to single hyphens' );
};

subtest 'create_with_unique_slug retries on collision' => sub {
    reset_db();
    my $first = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'My Plugin', { repo_url => 'https://github.com/a/my-plugin' }
    );
    is( $first->slug, 'my-plugin', 'first submission gets the plain slug' );

    my $second = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'My Plugin', { repo_url => 'https://github.com/b/my-plugin' }
    );
    is( $second->slug, 'my-plugin-2', 'second submission with the same base gets a suffixed slug' );

    my $third = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'My Plugin', { repo_url => 'https://github.com/c/my-plugin' }
    );
    is( $third->slug, 'my-plugin-3', 'third submission gets the next suffix' );
};
```

Also add `use TestDB qw(reset_db test_pg);` is already present at the top of this file, so
no import change is needed.

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/model_plugin.t
```
Expected: FAIL — `Can't locate object method "create_with_unique_slug"`.

- [ ] **Step 3: Implement it**

In `lib/KohaPluginStore/Model/Plugin.pm`, add (after the existing `releases` sub, before
the final `1;`):

```perl
sub create_with_unique_slug {
    my ( $self, $slug_source, $attrs ) = @_;

    my $base = lc($slug_source);
    $base =~ s/[^a-z0-9]+/-/g;
    $base =~ s/^-+|-+$//g;

    for my $attempt ( 1 .. 10 ) {
        my $candidate = $attempt == 1 ? $base : "$base-$attempt";
        my $plugin = eval { $self->create( { %$attrs, slug => $candidate } ) };
        return $plugin if $plugin;
        die $@ unless $@ =~ /plugins_slug_key/;
    }

    die "Could not generate a unique slug for '$slug_source' after 10 attempts";
}
```

- [ ] **Step 4: Run `t/model_plugin.t` again to verify it passes**

```bash
prove -l t/model_plugin.t
```
Expected: PASS.

- [ ] **Step 5: Run the full suite**

```bash
prove -l t/
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore/Model/Plugin.pm t/model_plugin.t
git commit -m "Add Model::Plugin::create_with_unique_slug"
```

---

### Task 5: `GitHub.pm` — four new functions

**Files:**
- Modify: `lib/KohaPluginStore/GitHub.pm`
- Modify: `t/github.t`

**Interfaces:**
- Produces (all called by fully-qualified name, per this file's established convention —
  never `use KohaPluginStore::GitHub qw(...)`):
  - `fetch_releases($access_token, $owner_repo)` → arrayref of `{ tag_name, name,
    published_at, author => { login, avatar_url }, assets => [ { name,
    browser_download_url }, ... ] }`, or `[]` on any failure. Up to 10 most recent
    releases.
  - `fetch_release_by_tag($access_token, $owner_repo, $tag_name)` → same per-release shape
    as one entry of `fetch_releases`, or `undef` on any failure.
  - `download_kpz($access_token, $download_url, $dest_path)` → `1` on success (asset
    streamed to `$dest_path`), `undef`/false on any failure.
  - `fetch_contributors($access_token, $owner_repo)` → arrayref of `{ github_username,
    avatar_url, contributions_count }`, or `[]` on any failure.

- [ ] **Step 1: Write failing tests for the no-token edge cases**

Append to `t/github.t`, before `done_testing();`:

```perl
subtest 'fetch_releases with no token returns an empty list' => sub {
    is_deeply( KohaPluginStore::GitHub::fetch_releases( undef, 'https://github.com/a/b' ), [], 'undef token' );
};

subtest 'fetch_release_by_tag with no token returns undef' => sub {
    is( KohaPluginStore::GitHub::fetch_release_by_tag( undef, 'https://github.com/a/b', 'v1.0.0' ), undef, 'undef token' );
};

subtest 'download_kpz with no token returns undef' => sub {
    is( KohaPluginStore::GitHub::download_kpz( undef, 'https://example.com/x.kpz', '/tmp/x.kpz' ), undef, 'undef token' );
};

subtest 'fetch_contributors with no token returns an empty list' => sub {
    is_deeply( KohaPluginStore::GitHub::fetch_contributors( undef, 'https://github.com/a/b' ), [], 'undef token' );
};
```

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/github.t
```
Expected: FAIL — `Undefined subroutine &KohaPluginStore::GitHub::fetch_releases` (and
similarly for the other three).

- [ ] **Step 3: Implement the four functions**

In `lib/KohaPluginStore/GitHub.pm`, add (after the existing `fetch_public_repos`, before
the final `1;`):

```perl
sub fetch_releases {
    my ( $access_token, $owner_repo ) = @_;

    return [] unless $access_token;

    my $api_repo = $owner_repo =~ s{^https://github\.com/}{https://api.github.com/repos/}r;
    my $tx = Mojo::UserAgent->new->get(
        "$api_repo/releases?per_page=10" => {
            Accept        => 'application/vnd.github+json',
            Authorization => 'Bearer ' . $access_token,
        }
    );

    return [] unless $tx->result->code == 200;

    return [ map { _trim_release($_) } @{ $tx->result->json } ];
}

sub fetch_release_by_tag {
    my ( $access_token, $owner_repo, $tag_name ) = @_;

    return unless $access_token && $tag_name;

    my $api_repo = $owner_repo =~ s{^https://github\.com/}{https://api.github.com/repos/}r;
    my $tx = Mojo::UserAgent->new->get(
        "$api_repo/releases/tags/$tag_name" => {
            Accept        => 'application/vnd.github+json',
            Authorization => 'Bearer ' . $access_token,
        }
    );

    return unless $tx->result->code == 200;

    return _trim_release( $tx->result->json );
}

sub download_kpz {
    my ( $access_token, $download_url, $dest_path ) = @_;

    return unless $access_token && $download_url;

    my $tx = Mojo::UserAgent->new( max_redirects => 5 )->get(
        $download_url => {
            Accept        => 'application/octet-stream',
            Authorization => 'Bearer ' . $access_token,
        }
    );

    return unless $tx->result->code == 200;

    $tx->result->content->asset->move_to($dest_path);
    return 1;
}

sub fetch_contributors {
    my ( $access_token, $owner_repo ) = @_;

    return [] unless $access_token;

    my $api_repo = $owner_repo =~ s{^https://github\.com/}{https://api.github.com/repos/}r;
    my $tx = Mojo::UserAgent->new->get(
        "$api_repo/contributors?per_page=100" => {
            Accept        => 'application/vnd.github+json',
            Authorization => 'Bearer ' . $access_token,
        }
    );

    return [] unless $tx->result->code == 200;

    return [
        map {
            {
                github_username     => $_->{login},
                avatar_url          => $_->{avatar_url},
                contributions_count => $_->{contributions},
            }
        } @{ $tx->result->json }
    ];
}

sub _trim_release {
    my ($release) = @_;

    return {
        tag_name     => $release->{tag_name},
        name         => $release->{name},
        published_at => $release->{published_at},
        author       => {
            login      => $release->{author}{login},
            avatar_url => $release->{author}{avatar_url},
        },
        assets => [
            map { { name => $_->{name}, browser_download_url => $_->{browser_download_url} } }
                @{ $release->{assets} }
        ],
    };
}
```

- [ ] **Step 4: Run `t/github.t` again to verify it passes**

```bash
prove -l t/github.t
```
Expected: PASS.

- [ ] **Step 5: Run the full suite**

```bash
prove -l t/
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore/GitHub.pm t/github.t
git commit -m "Add fetch_releases, fetch_release_by_tag, download_kpz, fetch_contributors"
```

---

### Task 6: The `process_plugin_version` Minion task

**Files:**
- Create: `lib/KohaPluginStore/Task/ProcessPluginVersion.pm`
- Modify: `lib/KohaPluginStore.pm` (register the task)
- Modify: `cpanfile` (add `Digest::SHA` — core since Perl 5.9.3, but declared explicitly
  per this project's existing style of listing every module it uses directly)
- Test: `t/task_process_plugin_version.t` (new)

**Interfaces:**
- Consumes: `KohaPluginStore::GitHub::download_kpz`/`fetch_contributors` (Task 5),
  `KohaPluginStore::Model::PluginVersion`/`Plugin`/`PluginContributor` (Task 3),
  `$c->app->plugin('Config')->{github_app_token}` (Task 2).
- Produces: the `process_plugin_version` Minion task, taking a single argument
  (`$plugin_version_id`). On completion, the corresponding `plugin_versions` row has
  `status` set to `published` or `changes_requested` (with `error_message` set in the
  latter case), and — on success — `content_digest`, `version`, `koha_min_version` set,
  the parent `plugins` row has `name`/`description`/`class_name` set, and
  `plugin_contributors` rows exist for the repo (best-effort).

- [ ] **Step 1: Write a failing test for the success path**

Create `t/task_process_plugin_version.t`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use File::Temp qw(tempdir);
use File::Copy 'copy';
use Archive::Zip;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::PluginContributor;

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );
$t->app->plugin( Minion => { Pg => test_pg() } );

sub make_kpz {
    my ($plugin_pm_contents) = @_;
    my $dir      = tempdir( CLEANUP => 1 );
    my $zip_path = "$dir/fixture.kpz";
    my $zip      = Archive::Zip->new;
    $zip->addString( $plugin_pm_contents, 'Widget.pm' );
    $zip->writeToFileNamed($zip_path);
    return $zip_path;
}

my $valid_plugin_pm = <<'PERL';
package Koha::Plugin::Test::Widget;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name => 'Widget',
    description => 'A test widget',
    author => 'Someone',
    minimum_version => '23.05',
};
1;
PERL

subtest 'successful processing publishes the version' => sub {
    reset_db();
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'dev' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $developer->id }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $plugin->id,
            tag_name  => 'v1.0.0',
            kpz_url   => 'https://example.com/widget.kpz',
            status    => 'submitted',
        }
    );

    my $fixture_zip = make_kpz($valid_plugin_pm);

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors = sub {
        return [ { github_username => 'octocat', avatar_url => 'https://example.com/a.png', contributions_count => 5 } ];
    };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is published' );
    ok( $reloaded->content_digest, 'content_digest was computed' );
    is( $reloaded->koha_min_version, '23.05', 'koha_min_version parsed from metadata' );

    my $reloaded_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded_plugin->name, 'Widget', 'plugin name populated from metadata' );
    is( $reloaded_plugin->class_name, 'Koha::Plugin::Test::Widget', 'class_name populated' );

    my @contributors = KohaPluginStore::Model::PluginContributor->new( pg => test_pg() )->search(
        { plugin_id => $plugin->id }
    );
    is( scalar @contributors, 1, 'one contributor recorded' );
    is( $contributors[0]->github_username, 'octocat', 'contributor username recorded' );
};

done_testing();
```

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/task_process_plugin_version.t
```
Expected: FAIL — the job either isn't registered (`Unknown task`) or the status never
changes from `submitted`, since `process_plugin_version` doesn't exist yet.

- [ ] **Step 3: Write the task module**

Create `lib/KohaPluginStore/Task/ProcessPluginVersion.pm`:

```perl
package KohaPluginStore::Task::ProcessPluginVersion;

use Modern::Perl;
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use File::Find;
use File::Slurp;
use String::Util 'trim';
use Archive::Zip;

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::PluginContributor;
use KohaPluginStore::GitHub;

sub register {
    my ($app) = @_;
    $app->minion->add_task( process_plugin_version => \&run );
}

sub run {
    my ( $job, $plugin_version_id ) = @_;

    my $app = $job->app;
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => $app->pg )->find( { id => $plugin_version_id } );
    die "plugin_version $plugin_version_id not found\n" unless $version;

    $version->update( { status => 'checks_running' } );

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $app->pg )->find( { id => $version->plugin_id } );

    my $config = $app->config;
    my $token  = $config->{github_app_token};

    my $tmp_dir  = tempdir( CLEANUP => 1 );
    my $kpz_path = "$tmp_dir/plugin.kpz";

    my $downloaded = KohaPluginStore::GitHub::download_kpz( $token, $version->kpz_url, $kpz_path );
    unless ($downloaded) {
        return $version->update(
            {
                status        => 'changes_requested',
                error_message => 'Could not download the .kpz asset from GitHub -- it may not be publicly accessible.',
            }
        );
    }

    my $extract_dir = "$tmp_dir/extracted";
    my $zip         = Archive::Zip->new($kpz_path);
    unless ($zip) {
        return $version->update(
            { status => 'changes_requested', error_message => 'The downloaded .kpz file is not a valid zip archive.' }
        );
    }
    for my $member ( $zip->members ) {
        $member->extractToFileNamed( "$extract_dir/" . $member->fileName );
    }

    my ( $plugin_class_file, $plugin_class_name ) = _find_plugin_class($extract_dir);
    unless ($plugin_class_file) {
        return $version->update(
            {
                status        => 'changes_requested',
                error_message => 'Plugin class file not found. Make sure the plugin has a class containing \'use base qw(Koha::Plugins::Base)\'.',
            }
        );
    }
    unless ($plugin_class_name) {
        return $version->update(
            {
                status        => 'changes_requested',
                error_message => 'Plugin class name not found. Make sure the plugin class file contains \'package Name;\'.',
            }
        );
    }

    my $metadata = _parse_metadata($plugin_class_file);
    unless ($metadata) {
        return $version->update(
            {
                status        => 'changes_requested',
                error_message => 'Plugin metadata not found. Make sure the plugin class contains \'our $metadata = { ... }\'.',
            }
        );
    }
    unless ( $metadata->{minimum_version} ) {
        return $version->update(
            { status => 'changes_requested', error_message => 'Plugin metadata is missing \'minimum_version\'.' }
        );
    }

    my $digest = do {
        open my $fh, '<:raw', $kpz_path or die "Could not open $kpz_path: $!";
        local $/;
        sha256_hex(<$fh>);
    };

    $plugin->update(
        {
            name        => $metadata->{name},
            description => $metadata->{description},
            class_name  => $plugin_class_name,
        }
    );

    my $contributors = eval { KohaPluginStore::GitHub::fetch_contributors( $token, $plugin->repo_url ) } || [];
    for my $contributor (@$contributors) {
        my $existing = KohaPluginStore::Model::PluginContributor->new( pg => $app->pg )->find(
            { plugin_id => $plugin->id, github_username => $contributor->{github_username} }
        );
        if ($existing) {
            $existing->update( { contributions_count => $contributor->{contributions_count}, fetched_at => \'now()' } );
        }
        else {
            KohaPluginStore::Model::PluginContributor->new( pg => $app->pg )->create(
                { plugin_id => $plugin->id, %$contributor }
            );
        }
    }

    $version->update(
        {
            status           => 'published',
            content_digest   => $digest,
            version          => $metadata->{version},
            koha_min_version => $metadata->{minimum_version},
        }
    );
}

sub _find_plugin_class {
    my ($plugin_dir) = @_;

    return unless -d $plugin_dir;

    my $plugin_class_file;
    my $plugin_class_name;

    find(
        {
            wanted => sub {
                return unless -f $_ && -T _;
                open my $fh, '<', $_ or die "Could not open file: $!";
                while ( my $line = <$fh> ) {
                    $line = trim($line);
                    if ( $line =~ /use (?:base|parent)/ && $line =~ /Koha::Plugins::Base/ ) {
                        $plugin_class_file = $File::Find::name;

                        open my $class_fh, '<', $plugin_class_file or die "Could not open file: $plugin_class_file";
                        while ( my $class_line = <$class_fh> ) {
                            if ( $class_line =~ /^package/ ) {
                                $plugin_class_name = $class_line;
                                $plugin_class_name =~ s/^package\s+//;
                                $plugin_class_name =~ s/;$//;
                                $plugin_class_name =~ s/\s+//g;
                            }
                        }
                        close $class_fh;
                        last;
                    }
                }
                close $fh;
            },
            no_chdir => 1,
        },
        $plugin_dir
    );

    return ( $plugin_class_file, $plugin_class_name );
}

sub _parse_metadata {
    my ($plugin_class_file) = @_;

    return unless $plugin_class_file;

    my $metadata_contents = read_file($plugin_class_file);
    my $plugin_metadata;

    if ( $metadata_contents =~ /our \$metadata = (\{.*?\});(?!\w)/si ) {
        my $extracted_metadata = $1;
        my $metadata_variables;
        while ( $extracted_metadata =~ /\$([a-zA-Z_]+)\b/g ) {
            my $variable = $1;
            if ( $metadata_contents =~ /(our \$$variable.*?= .*?;)/si ) {
                my $value = $1;
                $value =~ s/our \$$variable.*?= //;
                $value =~ s/;//;
                $value = trim($value);
                $metadata_variables->{ '$' . $variable } = $value;
            }
        }

        for my $key ( keys %$metadata_variables ) {
            $extracted_metadata =~ s/\Q$key\E/$metadata_variables->{$key}/;
        }

        eval( '$plugin_metadata = ' . $extracted_metadata . ';' );
        if ($@) {
            warn "Error evaluating metadata: $@";
        }
    }

    return unless ref($plugin_metadata) eq 'HASH' && scalar keys %$plugin_metadata > 0;
    return $plugin_metadata;
}

1;
```

This moves `_get_plugin_class_file_and_name`/`_get_plugin_metadata`'s logic verbatim out
of `Controller::Plugins` (Tasks 7/8 delete the originals once nothing calls them anymore).

- [ ] **Step 4: Register the task**

In `lib/KohaPluginStore.pm`, add near the top:
```perl
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
```
becomes:
```perl
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Task::ProcessPluginVersion;
```

And in `startup()`, change:
```perl
    $self->plugin( Minion => { Pg => $self->pg } );

    push @{ $self->commands->namespaces }, 'KohaPluginStore::Command';
```
to:
```perl
    $self->plugin( Minion => { Pg => $self->pg } );
    KohaPluginStore::Task::ProcessPluginVersion::register($self);

    push @{ $self->commands->namespaces }, 'KohaPluginStore::Command';
```

- [ ] **Step 5: Add `Digest::SHA` to `cpanfile`**

```perl
requires 'Digest::SHA';
```

- [ ] **Step 6: Run `t/task_process_plugin_version.t` again to verify it passes**

```bash
prove -l t/task_process_plugin_version.t
```
Expected: PASS.

- [ ] **Step 7: Write failing tests for the failure modes**

Append to `t/task_process_plugin_version.t`, before `done_testing();`:

```perl
subtest 'download failure sets changes_requested with a specific message' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub { return 0 };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'changes_requested', 'status is changes_requested' );
    like( $reloaded->error_message, qr/not be publicly accessible/, 'error message explains the likely cause' );
};

subtest 'a zip with no plugin class file sets changes_requested' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_kpz("package Not::A::Plugin;\n1;\n");

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'changes_requested', 'status is changes_requested' );
    like( $reloaded->error_message, qr/class file not found/, 'error message names the problem' );
};

subtest 'missing minimum_version sets changes_requested' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $bad_plugin_pm = <<'PERL';
package Koha::Plugin::Test::Widget;
use base qw(Koha::Plugins::Base);
our $metadata = { name => 'Widget' };
1;
PERL
    my $fixture_zip = make_kpz($bad_plugin_pm);

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors = sub { return [] };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'changes_requested', 'status is changes_requested' );
    like( $reloaded->error_message, qr/minimum_version/, 'error message names the missing field' );
};

subtest 'a contributors fetch failure does not block publishing' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_kpz($valid_plugin_pm);

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors = sub { die 'GitHub is down' };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is still published despite the contributors fetch failing' );
};
```

- [ ] **Step 8: Run the full test file to verify everything passes**

```bash
prove -l t/task_process_plugin_version.t
```
Expected: PASS (6 subtests).

- [ ] **Step 9: Run the full suite**

```bash
prove -l t/
```
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/KohaPluginStore/Task/ProcessPluginVersion.pm lib/KohaPluginStore.pm \
    cpanfile t/task_process_plugin_version.t
git commit -m "Add the process_plugin_version Minion task"
```

---

### Task 7: Reshape `new_plugin`/`new_plugin_confirm` around tag selection and async processing

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm`
- Modify: `templates/new-plugin-step2.html.ep`
- Delete: `templates/new-plugin-confirm.html.ep`
- Modify: `t/plugins_add_form.t` (unaffected in shape, but re-verify it still passes)
- Modify: `t/plugins_new_plugin_ownership.t`
- Test: `t/plugins_new_plugin.t` (new — replaces the metadata-parsing assertions that used
  to live in this area, since parsing itself moved to Task 6's task and is tested there)

**Interfaces:**
- Consumes: `KohaPluginStore::GitHub::fetch_releases`/`fetch_release_by_tag` (Task 5),
  `KohaPluginStore::Model::Plugin::create_with_unique_slug` (Task 4), the `github_app_token`
  config key (Task 2), the `process_plugin_version` task (Task 6).
- Produces: `new_plugin` renders `new-plugin-step2` with a tag-picker instead of a
  metadata-confirm table. `new_plugin_confirm` creates rows and redirects to
  `/plugins/:slug` instead of rendering a confirmation template.

- [ ] **Step 1: Write a failing test for the reshaped `new_plugin`**

Create `t/plugins_new_plugin.t`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );
$t->app->plugin( Minion => { Pg => test_pg() } );

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

subtest 'shows a list of releases to choose from, eligible ones selectable' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_releases = sub {
        return [
            {
                tag_name => 'v1.0.0', name => 'v1.0.0', published_at => '2026-01-01T00:00:00Z',
                author => { login => 'octocat', avatar_url => 'https://example.com/a.png' },
                assets => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
            },
            {
                tag_name => 'v0.9.0', name => 'v0.9.0', published_at => '2025-01-01T00:00:00Z',
                author => { login => 'octocat', avatar_url => 'https://example.com/a.png' },
                assets => [],
            },
        ];
    };

    $t->post_ok( '/new-plugin' => form => { plugin_repo => 'https://github.com/octocat/Hello-World' } )
      ->status_is(200)
      ->element_exists('input[type="radio"][value="v1.0.0"]')
      ->element_exists_not('input[type="radio"][value="v0.9.0"]')
      ->text_like( 'body' => qr/one and only one/ );
};

subtest 'submitting a chosen tag creates rows and enqueues a job' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_release_by_tag = sub {
        return {
            tag_name => 'v1.0.0', name => 'v1.0.0', published_at => '2026-01-01T00:00:00Z',
            author => { login => 'octocat', avatar_url => 'https://example.com/a.png' },
            assets => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
        };
    };

    $t->post_ok(
        '/new-plugin-confirm' => form => {
            plugin_repo => 'https://github.com/octocat/Hello-World',
            tag_name    => 'v1.0.0',
        }
    )->status_is(302);

    my $location = $t->tx->res->headers->location;
    like( $location, qr{^/plugins/hello-world}, 'redirects to the new plugin detail page' );

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { repo_url => 'https://github.com/octocat/Hello-World' } );
    ok( $plugin, 'a plugin row was created' );
    is( $plugin->slug, 'hello-world', 'slug derived from the repo name' );

    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { plugin_id => $plugin->id } );
    is( $version->status, 'submitted', 'version starts as submitted' );
    is( $version->author_username, 'octocat', 'author captured from the release JSON' );

    my $job_count = $t->app->minion->jobs( { tasks => ['process_plugin_version'] } )->total;
    is( $job_count, 1, 'a process_plugin_version job was enqueued' );
};

done_testing();
```

Add `use KohaPluginStore::Model::Plugin;` and `use KohaPluginStore::Model::PluginVersion;`
near the top of this new file, alongside the existing `use lib 't/lib';` line.

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/plugins_new_plugin.t
```
Expected: FAIL — the current `new_plugin` still expects/returns the old confirm-page shape
and there's no radio-button tag picker yet.

- [ ] **Step 3: Reshape `new_plugin` and `new_plugin_confirm`**

In `lib/KohaPluginStore/Controller/Plugins.pm`, replace the entire `new_plugin` sub
(everything from `sub new_plugin ($c) {` through its closing `}`) with:

```perl
sub new_plugin ($c) {
    my $plugin_repo = $c->param('plugin_repo');

    my $developer_repos = KohaPluginStore::GitHub::fetch_public_repos( $c->session->{github_access_token} );
    my $repo_is_owned   = grep { $_->{html_url} eq $plugin_repo } @$developer_repos;
    return $c->_exit_with_error_message(
        'That repository is not in the list of your public GitHub repositories. Please pick one from the dropdown.'
    ) unless $repo_is_owned;

    my $config   = $c->app->plugin('Config');
    my $releases = KohaPluginStore::GitHub::fetch_releases( $config->{github_app_token}, $plugin_repo );
    return $c->_exit_with_error_message('Could not fetch releases from GitHub for this repository.')
        unless @$releases;

    for my $release (@$releases) {
        my @kpz_assets = grep { $_->{name} =~ /\.kpz$/ } @{ $release->{assets} };
        if ( scalar @kpz_assets == 1 ) {
            $release->{eligible} = 1;
        }
        else {
            $release->{eligible}         = 0;
            $release->{ineligible_reason} =
                'Release must contain one and only one \'.kpz\' asset. Found: ' . scalar @kpz_assets;
        }
    }

    $c->stash( plugin_repo => $plugin_repo, releases => $releases );
    $c->render('new-plugin-step2');
}
```

And replace the entire `new_plugin_confirm` sub with:

```perl
sub new_plugin_confirm ($c) {
    my $plugin_repo = $c->param('plugin_repo');
    my $tag_name    = $c->param('tag_name');

    unless ( $c->session->{developer} ) {
        return $c->render( text => 'Unauthorized', status => 401 );
    }

    my $developer_repos = KohaPluginStore::GitHub::fetch_public_repos( $c->session->{github_access_token} );
    my $repo_is_owned   = grep { $_->{html_url} eq $plugin_repo } @$developer_repos;
    return $c->_exit_with_error_message(
        'That repository is not in the list of your public GitHub repositories. Please pick one from the dropdown.'
    ) unless $repo_is_owned;

    my $config  = $c->app->plugin('Config');
    my $token   = $config->{github_app_token};
    my $release = KohaPluginStore::GitHub::fetch_release_by_tag( $token, $plugin_repo, $tag_name );
    return $c->_exit_with_error_message('Could not re-fetch that release from GitHub. Please try again.')
        unless $release;

    my @kpz_assets = grep { $_->{name} =~ /\.kpz$/ } @{ $release->{assets} };
    return $c->_exit_with_error_message(
        'Release must contain one and only one \'.kpz\' asset. Found: ' . scalar @kpz_assets )
        unless scalar @kpz_assets == 1;

    my ($repo_name) = $plugin_repo =~ m{([^/]+)/?$};

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->create_with_unique_slug(
        $repo_name,
        {
            repo_url     => $plugin_repo,
            developer_id => $c->session->{developer}->{id},
        }
    );

    my $new_version = eval {
        KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->create(
            {
                plugin_id         => $plugin->id,
                tag_name          => $release->{tag_name},
                name              => $release->{name},
                date_released     => $release->{published_at},
                kpz_url           => $kpz_assets[0]->{browser_download_url},
                author_username   => $release->{author}->{login},
                author_avatar_url => $release->{author}->{avatar_url},
                status            => 'submitted',
            }
        );
    };
    return $c->_exit_with_error_message('That release has already been submitted.')
        if !$new_version && $@ =~ /plugin_versions_plugin_id_tag_name_key/;
    die $@ if !$new_version;

    $c->minion->enqueue( process_plugin_version => [ $new_version->id ], { attempts => 3 } );

    return $c->redirect_to( '/plugins/' . $plugin->slug );
}
```

Delete `_get_latest_release_from_github` entirely (nothing calls it anymore — `edit_form`
still uses `_get_releases_from_github`, which Task 8 removes separately).

- [ ] **Step 4: Repurpose the step-2 template**

Replace the entire contents of `templates/new-plugin-step2.html.ep` with:

```eplite
% title "Choose a release";
% layout 'default';
% my $errors = stash 'errors';
% my $plugin_repo = stash 'plugin_repo';
% my $releases = stash 'releases';

% content_for 'sidebar' => begin
  %= include 'partial/side_menu'
% end

<h2><%= title %></h2>

% if ($errors) {
  <h3 class="text-danger">Errors found:</h3>
  % foreach my $error ( @{$errors} ) {
        %= t li => (class => 'text-danger') => $error
  % }
  %= link_to '/new-plugin' => (class => 'btn btn-primary') => begin
  Return
  % end
% } else {
  %= form_for 'new-plugin-confirm' => (method => 'POST') => begin
    <input type="hidden" name="plugin_repo" value="<%= $plugin_repo %>">
    <table class="table">
      <thead>
        <tr>
          <th></th>
          <th>Name</th>
          <th>Tag</th>
          <th>Published at</th>
        </tr>
      </thead>
      <tbody>
        % for my $release (@$releases) {
        <tr>
          <td>
            % if ($release->{eligible}) {
            <input required type="radio" name="tag_name" value="<%= $release->{tag_name} %>">
            % } else {
            <i class='bx bx-error text-danger'></i>
            % }
          </td>
          %= t td => $release->{name}
          %= t td => $release->{tag_name}
          %= t td => $release->{published_at}
          % if (!$release->{eligible}) {
          %= t td => (class => 'text-danger') => $release->{ineligible_reason}
          % }
        </tr>
        % }
      </tbody>
    </table>
    <button type="submit" class="btn btn-primary">Continue</button>
  % end
% }
```

- [ ] **Step 5: Delete the now-unused confirm template**

```bash
git rm templates/new-plugin-confirm.html.ep
```

- [ ] **Step 6: Run `t/plugins_new_plugin.t` again to verify it passes**

```bash
prove -l t/plugins_new_plugin.t
```
Expected: PASS.

- [ ] **Step 7: Update `t/plugins_new_plugin_ownership.t` for the new shape**

This file's existing subtest posts a `plugin_repo` not in the developer's owned list
straight to `/new-plugin` and expects an error naming "not in the list of your public
GitHub repositories" — that check still happens first, unchanged, in both `new_plugin` and
`new_plugin_confirm`. Update the stubbed `_get_latest_release_from_github` reference (which
no longer exists) to `_get_releases_from_github` is NOT needed here since ownership is
checked *before* any release fetch — but this file was stubbing
`_get_latest_release_from_github` specifically to prove it's never reached. Change:

```perl
    *KohaPluginStore::Controller::Plugins::_get_latest_release_from_github = sub {
        die 'should not be called for an unowned repo';
    };
```
to:
```perl
    *KohaPluginStore::GitHub::fetch_releases = sub {
        die 'should not be called for an unowned repo';
    };
```

Also update the `post_ok` target — this test currently posts straight to `/new-plugin`
expecting the ownership check to fire before any release fetch, which is still exactly
true of the reshaped `new_plugin`, so no other change is needed in this file.

- [ ] **Step 8: Run it to verify it still passes**

```bash
prove -l t/plugins_new_plugin_ownership.t
```
Expected: PASS.

- [ ] **Step 9: Run the full suite**

```bash
prove -l t/
```
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm templates/new-plugin-step2.html.ep \
    t/plugins_new_plugin.t t/plugins_new_plugin_ownership.t
git rm templates/new-plugin-confirm.html.ep
git commit -m "Reshape new_plugin/new_plugin_confirm around tag selection and async processing"
```

---

### Task 8: Reshape `edit_form`/`new_release` the same way

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (`edit_form`, delete now-dead
  private helpers)
- Modify: `lib/KohaPluginStore/Controller/Releases.pm` (`new_release`)
- Modify: `templates/plugins/edit.html.ep`
- Modify: `t/releases.t`

**Interfaces:**
- Consumes: same as Task 7 — `fetch_releases`/`fetch_release_by_tag` (Task 5),
  `github_app_token` (Task 2), `process_plugin_version` (Task 6).
- Produces: `edit_form` no longer downloads/parses each previewed release; `new_release`
  creates a row and enqueues a job instead of trusting posted hidden fields.

- [ ] **Step 1: Reshape `edit_form`**

In `lib/KohaPluginStore/Controller/Plugins.pm`, replace the entire `edit_form` sub with:

```perl
sub edit_form {
    my $c = shift;

    my $plugin_id = $c->param('id');
    my $plugin    = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find(
        {
            id => $plugin_id,
        }
    );

    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;
    return $c->render( text => 'Unauthorized',     status => 401 ) unless $c->session->{developer}->{id} == $plugin->developer_id;

    my $config          = $c->app->plugin('Config');
    my $github_releases = KohaPluginStore::GitHub::fetch_releases( $config->{github_app_token}, $plugin->repo_url );

    my $existing_tags = { map { $_->tag_name => 1 } @{ $plugin->releases } };

    foreach my $release (@$github_releases) {
        if ( $existing_tags->{ $release->{tag_name} } ) {
            $release->{message}->{success} = 'Release has already been submitted.';
            next;
        }

        my @kpz_assets = grep { $_->{name} =~ /\.kpz$/ } @{ $release->{assets} };
        if ( scalar @kpz_assets != 1 ) {
            $release->{message}->{error} = 'Release must contain one and only one \'.kpz\' asset.';
        }
    }

    $c->stash( plugin          => $plugin );
    $c->stash( github_releases => $github_releases );
    $c->render('plugins/edit');
}
```

Then delete `_get_releases_from_github`, `_download_plugin`, `_get_plugin_class_file_and_name`,
and `_get_plugin_metadata` entirely — nothing in `Controller::Plugins` calls any of them
any more (their logic now lives in `KohaPluginStore::Task::ProcessPluginVersion`, added in
Task 6).

- [ ] **Step 2: Reshape `new_release`**

Replace the entire contents of `lib/KohaPluginStore/Controller/Releases.pm` with:

```perl
package KohaPluginStore::Controller::Releases;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::GitHub;

sub new_release ($c) {
    my $plugin_id = $c->param('plugin_id');
    my $tag_name  = $c->param('tag_name');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { id => $plugin_id } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;
    return $c->render( text => 'Unauthorized', status => 401 )
        unless $c->session->{developer}->{id} == $plugin->developer_id;

    my $config  = $c->app->plugin('Config');
    my $token   = $config->{github_app_token};
    my $release = KohaPluginStore::GitHub::fetch_release_by_tag( $token, $plugin->repo_url, $tag_name );
    return $c->render( text => 'Could not re-fetch that release from GitHub', status => 502 ) unless $release;

    my @kpz_assets = grep { $_->{name} =~ /\.kpz$/ } @{ $release->{assets} };
    return $c->render( text => 'Release must contain one and only one \'.kpz\' asset', status => 422 )
        unless scalar @kpz_assets == 1;

    my $new_version = eval {
        KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->create(
            {
                plugin_id         => $plugin_id,
                tag_name          => $release->{tag_name},
                name              => $release->{name},
                date_released     => $release->{published_at},
                kpz_url           => $kpz_assets[0]->{browser_download_url},
                author_username   => $release->{author}->{login},
                author_avatar_url => $release->{author}->{avatar_url},
                status            => 'submitted',
            }
        );
    };
    return $c->render( text => 'That release has already been submitted', status => 409 )
        if !$new_version && $@ =~ /plugin_versions_plugin_id_tag_name_key/;
    die $@ if !$new_version;

    $c->minion->enqueue( process_plugin_version => [ $new_version->id ], { attempts => 3 } );

    return $c->redirect_to( '/plugins/' . $plugin->slug );
}

1;
```

- [ ] **Step 3: Simplify the releases table in `templates/plugins/edit.html.ep`**

In the "Releases from github" table, change the header row from:
```eplite
        <tr>
          <th>Name</th>
          <th>Tag name</th>
          <th>Version</th>
          <th>Koha minimum version</th>
          <th>Published at</th>
          <th>Actions</th>
        </td>
      </thead>
```
to:
```eplite
        <tr>
          <th>Name</th>
          <th>Tag name</th>
          <th>Published at</th>
          <th>Actions</th>
        </td>
      </thead>
```

And change the body loop from:
```eplite
      % for my $release (@$github_releases) {
        % if ($release->{message}->{success} ){
        <tr class="text-success">
        % }elsif($release->{message}->{error}){
        <tr class="text-danger">
        % }else{
        <tr>
        % }
          %= t td => link_to $release->{name} || 'N/A' => $release->{html_url} => (target => '_blank')
          % if ($release->{message}->{error} ){
          %= t td => begin
            <%= $release->{tag_name} %> <i class='bx bx-error'></i>
          % end 
          % } else{
          %= t td => $release->{tag_name} 
          % }
          %= t td => $release->{version}
          %= t td => $release->{koha_minimum_version}
          %= t td => $release->{published_at}
          % if ($release->{message}->{success} ){
          %= t td => $release->{message}->{success}
          % } elsif($release->{message}->{error} ){
          %= t td => $release->{message}->{error}
          % } else{
          %= t td => form_for '/new-release' => (method => 'POST', id => 'new_release_form') => begin
            <input type="hidden" name="kpz_download" value="<%= $release->{assets}[0]->{browser_download_url} %>"></button>
            <input type="hidden" name="plugin_id" value="<%= $plugin->id %>"></button>
            <input type="hidden" name="release_metadata_name" value="<%= $release->{name} %>"></button>
            <input type="hidden" name="release_metadata_tag_name" value="<%= $release->{tag_name} %>"></button>
            <input type="hidden" name="release_metadata_date_released" value="<%= $release->{published_at} %>"></button>
            <input type="hidden" name="release_metadata_version" value="<%= $release->{version} %>"></button>
            <input type="hidden" name="release_metadata_koha_min_version" value="<%= $release->{koha_minimum_version} %>"></button>
            <button type="submit" class="btn btn-primary">Add this release</button>
          % end
          % }
        </tr>
      % }
```
to:
```eplite
      % for my $release (@$github_releases) {
        % if ($release->{message}->{success} ){
        <tr class="text-success">
        % }elsif($release->{message}->{error}){
        <tr class="text-danger">
        % }else{
        <tr>
        % }
          %= t td => $release->{name}
          %= t td => $release->{tag_name}
          %= t td => $release->{published_at}
          % if ($release->{message}->{success} ){
          %= t td => $release->{message}->{success}
          % } elsif($release->{message}->{error} ){
          %= t td => $release->{message}->{error}
          % } else{
          %= t td => form_for '/new-release' => (method => 'POST', id => 'new_release_form') => begin
            <input type="hidden" name="plugin_id" value="<%= $plugin->id %>">
            <input type="hidden" name="tag_name" value="<%= $release->{tag_name} %>">
            <button type="submit" class="btn btn-primary">Add this release</button>
          % end
          % }
        </tr>
      % }
```

(`$release->{html_url}`/`{version}`/`{koha_minimum_version}` no longer exist on the trimmed
`fetch_releases` shape from Task 5 — dropped along with the columns that used them, since
that data isn't known until the async job runs.)

- [ ] **Step 4: Rewrite `t/releases.t` for the new contract**

Replace the entire file with:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojo::Promise;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => '1', username => 'owner' }
);
my $other = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => '2', username => 'other' }
);
my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'coverflow', { name => 'CoverFlow', repo_url => 'https://github.com/owner/coverflow', developer_id => $owner->id }
);

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );
$t->app->plugin( Minion => { Pg => test_pg() } );

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
    *KohaPluginStore::GitHub::fetch_release_by_tag = sub {
        return {
            tag_name => 'v1.0.0', name => 'v1.0.0', published_at => '2026-01-01T00:00:00Z',
            author => { login => 'owner', avatar_url => 'https://example.com/a.png' },
            assets => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
        };
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
    $t->post_ok( '/new-release' => form => { plugin_id => $plugin->id, tag_name => 'v1.0.0' } )->status_is(404); # existing #TODO: should be 401
};

subtest 'a different developer cannot submit a release for someone else\'s plugin' => sub {
    login_as($other);
    $t->post_ok( '/new-release' => form => { plugin_id => $plugin->id, tag_name => 'v1.0.0' } )->status_is(401);
};

subtest 'the owning developer can submit a release' => sub {
    login_as($owner);
    $t->post_ok( '/new-release' => form => { plugin_id => $plugin->id, tag_name => 'v1.0.0' } )
      ->status_is(302)
      ->header_is( Location => '/plugins/coverflow' );

    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0' }
    );
    is( $version->status, 'submitted', 'version created with submitted status' );

    my $job_count = $t->app->minion->jobs( { tasks => ['process_plugin_version'] } )->total;
    is( $job_count, 1, 'a process_plugin_version job was enqueued' );
};

subtest 'submitting the same tag again is rejected' => sub {
    $t->post_ok( '/new-release' => form => { plugin_id => $plugin->id, tag_name => 'v1.0.0' } )->status_is(409);
};

done_testing();
```

- [ ] **Step 5: Run it to verify it passes**

```bash
prove -l t/releases.t
```
Expected: PASS.

- [ ] **Step 6: Run the full suite**

```bash
prove -l t/
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm lib/KohaPluginStore/Controller/Releases.pm \
    templates/plugins/edit.html.ep t/releases.t
git commit -m "Reshape edit_form/new_release around tag selection and async processing"
```

---

### Task 9: `GET /plugins/:slug` — the public detail/status page

**Files:**
- Modify: `lib/KohaPluginStore.pm` (route)
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (`show`)
- Create: `templates/plugins/show.html.ep`
- Test: `t/plugins_show.t` (new)

**Interfaces:**
- Produces: `GET /plugins/:slug`, public (no login required), rendering the plugin's
  info, its versions with `status`/`error_message`, and its contributors.

- [ ] **Step 1: Write failing tests**

Create `t/plugins_show.t`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

subtest 'unknown slug is a 404' => sub {
    $t->get_ok('/plugins/does-not-exist')->status_is(404);
};

subtest 'a published version shows no auto-refresh' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', version => '1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->text_is( 'h2' => 'Widget' )
      ->element_exists_not('meta[http-equiv="refresh"]');
};

subtest 'a submitted version shows the auto-refresh meta tag' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'submitted' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->element_exists('meta[http-equiv="refresh"]');
};

done_testing();
```

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/plugins_show.t
```
Expected: FAIL — `GET /plugins/:slug` doesn't exist yet (404 for every case, including the
ones expecting 200).

- [ ] **Step 3: Add the route**

In `lib/KohaPluginStore.pm`, change:
```perl
    $r->get('/plugins/edit/:id')->requires( user_authenticated => 1 )->to('plugins#edit_form');
```
to:
```perl
    $r->get('/plugins/edit/:id')->requires( user_authenticated => 1 )->to('plugins#edit_form');
    $r->get('/plugins/:slug')->to('plugins#show');
```

- [ ] **Step 4: Add the controller action**

In `lib/KohaPluginStore/Controller/Plugins.pm`, add (after `edit_form`, before
`list_all`):

```perl
sub show ($c) {
    my $slug = $c->param('slug');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { slug => $slug } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->search(
        { plugin_id => $plugin->id }, { order_by => { -desc => 'id' } }
    );
    my @contributors = KohaPluginStore::Model::PluginContributor->new( pg => $c->pg )->search(
        { plugin_id => $plugin->id }, { order_by => { -desc => 'contributions_count' } }
    );

    my $still_processing = grep { $_->status eq 'submitted' || $_->status eq 'checks_running' } @versions;

    $c->stash(
        plugin           => $plugin,
        versions         => \@versions,
        contributors     => \@contributors,
        still_processing => $still_processing,
    );
    $c->render('plugins/show');
}
```

Add `use KohaPluginStore::Model::PluginContributor;` alongside this file's existing `use`
statements at the top.

(`order_by => { -desc => 'id' }` rather than `date_released`, since a `submitted`/
`checks_running` version has no `date_released` yet — sorting by `id` keeps the most
recently-created version first regardless of processing state.)

- [ ] **Step 5: Create the template**

Create `templates/plugins/show.html.ep`:

```eplite
% my $plugin = stash 'plugin';
% my $versions = stash 'versions';
% my $contributors = stash 'contributors';
% my $still_processing = stash 'still_processing';
% title $plugin->name || 'Processing submission...';
% layout 'default';
% if ($still_processing) {
<meta http-equiv="refresh" content="5">
% }

% content_for 'sidebar' => begin
  %= include 'partial/side_menu'
% end

<h2><%= title %></h2>
% if ($plugin->description) {
<p><%= $plugin->description %></p>
% }

<h3>Versions</h3>
<table class="table">
  <thead>
    <tr>
      <th>Tag</th>
      <th>Version</th>
      <th>Status</th>
      <th>Details</th>
    </tr>
  </thead>
  <tbody>
    % for my $version (@$versions) {
    <tr>
      %= t td => $version->tag_name
      %= t td => ($version->version || '-')
      %= t td => $version->status
      %= t td => ($version->error_message || '')
    </tr>
    % }
  </tbody>
</table>

% if (@$contributors) {
<h3>Contributors</h3>
<ul class="list-unstyled">
  % for my $contributor (@$contributors) {
  <li><img src="<%= $contributor->avatar_url %>" width="24" height="24"> <%= $contributor->github_username %></li>
  % }
</ul>
% }
```

- [ ] **Step 6: Run `t/plugins_show.t` again to verify it passes**

```bash
prove -l t/plugins_show.t
```
Expected: PASS.

- [ ] **Step 7: Run the full suite**

```bash
prove -l t/
```
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/KohaPluginStore.pm lib/KohaPluginStore/Controller/Plugins.pm \
    templates/plugins/show.html.ep t/plugins_show.t
git commit -m "Add the public plugin detail/status page"
```

---

### Task 10: Minion worker in Docker, and doc updates

**Files:**
- Modify: `docker-compose.yml`
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Interfaces:** None — operational/documentation only.

- [ ] **Step 1: Add a worker service to `docker-compose.yml`**

Change:
```yaml
services:
  app:
    build: .
    depends_on:
      - postgres
    volumes:
      - .:/app
    ports:
      - "3000:3000"

  postgres:
```
to:
```yaml
services:
  app:
    build: .
    depends_on:
      - postgres
    volumes:
      - .:/app
    ports:
      - "3000:3000"

  worker:
    build: .
    depends_on:
      - postgres
    volumes:
      - .:/app
    command: ["perl", "script/koha_plugin_store", "minion", "worker"]

  postgres:
```

- [ ] **Step 2: Verify it starts correctly**

```bash
docker compose up -d --build
docker compose logs worker --tail 20
```
Expected: the worker container starts without error (Minion workers log little by
default when idle — absence of a crash/exit is what to check for; `docker compose ps`
should show it `Up`, not restarting).

- [ ] **Step 3: Update `CLAUDE.md`**'s "Plugin submission workflow" section

Replace the numbered list (currently describing the synchronous fetch→download→parse
pipeline) with:

```markdown
1. The developer picks a repo (constrained to their own public GitHub repos, §above) and
   a specific tagged release (`GET /repos/.../releases`, via the store's own
   `github_app_token` -- not the developer's login token). `new_plugin_confirm`/
   `new_release` re-fetch that exact release server-side, create the `plugins`/
   `plugin_versions` rows immediately with `status = 'submitted'`, and enqueue a Minion
   job -- they never download or parse anything themselves.
2. `KohaPluginStore::Task::ProcessPluginVersion` (the `process_plugin_version` Minion
   task) does the actual work: downloads the `.kpz` to a temp directory (never a
   permanent cache), extracts it, walks the tree for a file with `use base`/`use parent
   ... Koha::Plugins::Base`, regex-extracts the `our $metadata = { ... }` hash literal
   (same fragile-by-design approach as before -- parsing text, not executing the plugin),
   fetches the repo's contributors, computes a SHA-256 `content_digest`, and sets the
   version's `status` to `published` or `changes_requested` (with `error_message`)
   accordingly.
3. `GET /plugins/:slug` is the public page a developer watches while their submission
   processes -- it auto-refreshes every 5 seconds while any version is
   `submitted`/`checks_running`.
```

Also add, near the Commands section: a note that a Minion worker process must be running
for submissions to ever leave `status = 'submitted'` — `perl script/koha_plugin_store
minion worker` locally, or the `worker` service in `docker-compose.yml`.

- [ ] **Step 4: Update `README.md`**

In the "Notes" bullet list (under "Backend"), add:

```markdown
  - Plugin submission is asynchronous: picking a repo+tag creates the plugin/version rows
    immediately and a Minion background job does the actual download/parse/validation.
    A Minion worker process must be running for submissions to ever complete -- either
    `perl script/koha_plugin_store minion worker` locally, or the `worker` service in
    Docker (already included in `docker-compose.yml`).
```

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml CLAUDE.md README.md
git commit -m "Add a Minion worker service and document the async submission pipeline"
```

---

## Self-Review Notes

- **Spec coverage:** every design-doc section maps to a task — synchronous/async split
  (Tasks 7, 8, 6), data model (Task 3), slug generation (Task 4), GitHub token rename
  (Task 2), `GitHub.pm` additions (Task 5), Minion wiring (Tasks 1, 6, 10), new route/detail
  page (Task 9), error handling (Task 6's failure-mode subtests), testing conventions
  (every task). Non-goals are untouched by any task, as intended.
- **Type/name consistency checked:** `process_plugin_version` (task name), `slug`,
  `status`/`error_message`/`content_digest`/`author_username`/`author_avatar_url`
  (columns), `github_app_token` (config key), `create_with_unique_slug` (Model::Plugin
  method) — all used identically across every task that references them.
- **No placeholders** — every step above has real, complete code; nothing deferred to "add
  appropriate handling" language.
