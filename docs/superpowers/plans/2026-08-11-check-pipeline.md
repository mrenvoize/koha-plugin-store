# Automated Check Pipeline (Levels 1–2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `KohaPluginStore::Task::ProcessPluginVersion`'s binary pass/fail with a per-check `review_checks` table and a three-tier automated certification badge (`INCOMPLETE`/`STRUCTURAL`/`CERTIFIED`).

**Architecture:** A new `KohaPluginStore::Check::*` class per check (common `->new->run($extract_dir, $metadata, $context)` interface returning `{ passed => bool, message => str|undef }`), listed in `KohaPluginStore::Checks::ALL`, run in order from inside the existing `ProcessPluginVersion` Minion task. Only `PerlSyntax` executes untrusted code, so only it runs inside a locked-down Docker sandbox against a shallow-cloned Koha core checkout; every other check is a safe, unsandboxed static scan, metadata read, or GitHub API call.

**Tech Stack:** Perl (Mojolicious, Mojo::Pg, Minion), Postgres, `Koha::QA::PerlCritic` (new git-based cpanfile dependency), Docker (new operational dependency for the Minion worker).

## Global Constraints

- Every new file follows the existing project conventions: `use Modern::Perl;` (or `Mojo::Base ... -signatures` where the file already uses that style), `parent -norequire` for model subclasses.
- TDD throughout: write the failing test, run it, implement the minimal code, run it again, commit.
- Test seams for anything that shells out or hits the network follow the existing typeglob-override pattern (`no strict 'refs'; no warnings 'redefine'; *Package::sub = sub {...};`) already used for `KohaPluginStore::GitHub::fetch_all_repos` etc.
- `review_checks` is scoped to `plugin_version_id`, never `plugin_id` — certification is per-version.
- Tier computation is a strict AND-gate at each level (no scoring/weighting): any required check failing → `INCOMPLETE`; all required passing but any *gating* non-required check failing → `STRUCTURAL`; all required and all gating non-required passing → `CERTIFIED`. `KohaMaxVersion` and `GpgSignedTag` are recorded but never participate in this computation.
- Full detail and rationale for every decision below lives in `docs/superpowers/specs/2026-08-10-check-pipeline-design.md` — consult it if a task's "why" isn't obvious from the plan alone.

---

## Task 1: `review_checks` table, `certification_tier` column, and `Model::ReviewCheck`

**Files:**
- Modify: `lib/KohaPluginStore/Command/migrate.pm` (append migration 5)
- Modify: `lib/KohaPluginStore/Model/PluginVersion.pm` (add `certification_tier` to `_columns`)
- Create: `lib/KohaPluginStore/Model/ReviewCheck.pm`
- Test: `t/model_review_check.t`

**Interfaces:**
- Produces: `KohaPluginStore::Model::ReviewCheck->new( pg => $pg )->create({ plugin_version_id, check_name, required, passed, message })` (inherited from `Model::Base`), plus `->record({ plugin_version_id, check_name, required, passed, message })` — upserts on the `(plugin_version_id, check_name)` unique constraint. `KohaPluginStore::Model::PluginVersion` rows now respond to `->certification_tier`.

- [ ] **Step 1: Write the failing test**

Create `t/model_review_check.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::ReviewCheck;

reset_db();

subtest 'create and find a review check' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'Widget' } );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'submitted' }
    );

    my $check = KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->create(
        {
            plugin_version_id => $version->id,
            check_name        => 'perl_syntax',
            required          => 1,
            passed            => 1,
        }
    );

    ok( $check->id, 'id was assigned' );
    is( $check->check_name, 'perl_syntax', 'check_name accessor reads back' );

    my $found = KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->find(
        { plugin_version_id => $version->id, check_name => 'perl_syntax' }
    );
    ok( $found->passed, 'found the right row' );
};

subtest 'record() upserts on (plugin_version_id, check_name)' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'Widget2' } );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'submitted' }
    );

    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        { plugin_version_id => $version->id, check_name => 'perl_syntax', required => 1, passed => 0, message => 'first attempt' }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        { plugin_version_id => $version->id, check_name => 'perl_syntax', required => 1, passed => 1, message => undef }
    );

    my @rows = KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->search(
        { plugin_version_id => $version->id, check_name => 'perl_syntax' }
    );
    is( scalar @rows, 1, 'still only one row after a second record() call' );
    ok( $rows[0]->passed, 'the row reflects the latest call' );
};

subtest 'plugin_versions gained a certification_tier column' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'Widget3' } );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'submitted' }
    );
    $version->update( { certification_tier => 'CERTIFIED' } );

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->certification_tier, 'CERTIFIED', 'certification_tier round-trips through the DB' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/model_review_check.t`
Expected: FAIL — `review_checks` table doesn't exist yet (Postgres error) and `KohaPluginStore::Model::ReviewCheck` doesn't exist.

- [ ] **Step 3: Add the migration**

Append to the `__DATA__` section of `lib/KohaPluginStore/Command/migrate.pm`, immediately after the existing `-- 4 down` block:

```sql

-- 5 up
ALTER TABLE plugin_versions ADD COLUMN certification_tier TEXT;

CREATE TABLE review_checks (
    id                SERIAL PRIMARY KEY,
    plugin_version_id INTEGER REFERENCES plugin_versions(id) ON DELETE CASCADE,
    check_name        TEXT NOT NULL,
    required          BOOLEAN NOT NULL,
    passed            BOOLEAN NOT NULL,
    message           TEXT,
    checked_at        TIMESTAMPTZ DEFAULT now(),
    UNIQUE (plugin_version_id, check_name)
);

-- 5 down
DROP TABLE review_checks;
ALTER TABLE plugin_versions DROP COLUMN certification_tier;
```

Apply it to the test database:

Run: `KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@127.0.0.1:55432/koha_plugin_store' perl script/koha_plugin_store migrate`

(Substitute whatever `KOHA_PLUGIN_STORE_TEST_DSN`/local Postgres port this worktree's `t/lib/TestDB.pm` actually points at — check the file if unsure.)

- [ ] **Step 4: Add `certification_tier` to `PluginVersion`'s `_columns`**

In `lib/KohaPluginStore/Model/PluginVersion.pm`, change:

```perl
sub _columns {
    return [qw(id plugin_id name tag_name version koha_min_version kpz_url date_released status error_message content_digest author_username author_avatar_url)];
}
```

to:

```perl
sub _columns {
    return [qw(id plugin_id name tag_name version koha_min_version kpz_url date_released status error_message content_digest author_username author_avatar_url certification_tier)];
}
```

- [ ] **Step 5: Create `KohaPluginStore::Model::ReviewCheck`**

Create `lib/KohaPluginStore/Model/ReviewCheck.pm`:

```perl
package KohaPluginStore::Model::ReviewCheck;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

sub _table {
    return 'review_checks';
}

sub _columns {
    return [qw(id plugin_version_id check_name required passed message checked_at)];
}

sub record {
    my ( $self, $attrs ) = @_;

    my $row = $self->pg->db->query(
        q{
            INSERT INTO review_checks (plugin_version_id, check_name, required, passed, message)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (plugin_version_id, check_name)
            DO UPDATE SET passed = EXCLUDED.passed, message = EXCLUDED.message, checked_at = now()
            RETURNING *
        },
        $attrs->{plugin_version_id}, $attrs->{check_name}, $attrs->{required} ? 1 : 0,
        $attrs->{passed} ? 1 : 0, $attrs->{message}
    )->hash;

    return $self->_new_from_row($row);
}

1;
```

- [ ] **Step 6: Run test to verify it passes**

Run: `prove -l t/model_review_check.t`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/KohaPluginStore/Command/migrate.pm lib/KohaPluginStore/Model/PluginVersion.pm lib/KohaPluginStore/Model/ReviewCheck.pm t/model_review_check.t
git commit -m "Add review_checks table, certification_tier column, and Model::ReviewCheck"
```

---

## Task 2: `KohaPluginStore::Check::Base`

**Files:**
- Create: `lib/KohaPluginStore/Check/Base.pm`
- Test: `t/check_base.t`

**Interfaces:**
- Produces: every concrete check subclasses this and must implement `check_name()` (string), `required()` (0/1), `gates_certification()` (0/1), and `run($extract_dir, $metadata, $context)` returning `{ passed => bool, message => str|undef }`. `$context` is a hashref (repo/token/config info — see Task 14) that most checks ignore. Also produces `$self->find_files($dir, $pattern)` — returns a list of absolute paths under `$dir` (recursively) whose filename matches the `qr//` `$pattern`, or an empty list if `$dir` doesn't exist. Six later tasks (4, 6, 8, 9, 10, 11) use this instead of each writing their own `File::Find` block — this was caught during the pre-flight plan scan as duplication a reviewer would otherwise flag six separate times.

- [ ] **Step 1: Write the failing test**

Create `t/check_base.t`:

```perl
use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::Base;

package KohaPluginStore::Check::TestDummy;
use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
sub check_name         { 'test_dummy' }
sub required            { 1 }
sub gates_certification { 1 }
sub run ($self, $extract_dir, $metadata, $context) {
    return { passed => 1, message => undef };
}
package main;

subtest 'a subclass implementing run() works' => sub {
    my $check  = KohaPluginStore::Check::TestDummy->new;
    my $result = $check->run( '/tmp', {}, {} );
    ok( $result->{passed}, 'passed is true' );
    is( $check->check_name, 'test_dummy', 'check_name accessor' );
    ok( $check->required, 'required accessor' );
    ok( $check->gates_certification, 'gates_certification accessor' );
};

subtest 'the base class dies if run() is not overridden' => sub {
    my $check = KohaPluginStore::Check::Base->new;
    eval { $check->run( '/tmp', {}, {} ) };
    like( $@, qr/must implement run/, 'dies with a clear message' );
};

subtest 'find_files finds matching files recursively' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/t");
    write_file( "$dir/Widget.pm",  "package Widget;\n1;\n" );
    write_file( "$dir/t/basic.t",  "use Test::More;\nok(1);\ndone_testing();\n" );
    write_file( "$dir/README.md",  "# Widget\n" );

    my $check    = KohaPluginStore::Check::TestDummy->new;
    my @pm_files = $check->find_files( $dir, qr/\.pm$/ );
    is( scalar @pm_files, 1, 'found exactly one .pm file' );
    like( $pm_files[0], qr/Widget\.pm$/, 'found the right file' );
};

subtest 'find_files returns an empty list for a directory that does not exist' => sub {
    my $check = KohaPluginStore::Check::TestDummy->new;
    my @found = $check->find_files( '/no/such/dir', qr/\.pm$/ );
    is( scalar @found, 0, 'empty list, not a die' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/check_base.t`
Expected: FAIL — `Can't locate KohaPluginStore/Check/Base.pm`

- [ ] **Step 3: Write minimal implementation**

Create `lib/KohaPluginStore/Check/Base.pm`:

```perl
package KohaPluginStore::Check::Base;

use Mojo::Base -base, -signatures;
use File::Find;

sub run ($self, $extract_dir, $metadata, $context) {
    die ref($self) . ' must implement run()';
}

sub find_files ($self, $dir, $pattern) {
    return () unless -d $dir;

    my @matches;
    find(
        {
            wanted   => sub { push @matches, $File::Find::name if -f $_ && /$pattern/ },
            no_chdir => 1,
        },
        $dir
    );

    return @matches;
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/check_base.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Check/Base.pm t/check_base.t
git commit -m "Add KohaPluginStore::Check::Base"
```

---

## Task 3: `Check::ManifestCompleteness` (required)

**Files:**
- Create: `lib/KohaPluginStore/Check/ManifestCompleteness.pm`
- Test: `t/check_manifest_completeness.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Check::Base` (Task 2).
- Produces: `KohaPluginStore::Check::ManifestCompleteness->new->run($extract_dir, $metadata, $context)`.

- [ ] **Step 1: Write the failing test**

Create `t/check_manifest_completeness.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::Check::ManifestCompleteness;

subtest 'passes when version and license are present' => sub {
    my $check  = KohaPluginStore::Check::ManifestCompleteness->new;
    my $result = $check->run( '/unused', { version => '1.0', license => 'GPL-3.0' }, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails and names missing fields' => sub {
    my $check  = KohaPluginStore::Check::ManifestCompleteness->new;
    my $result = $check->run( '/unused', { version => '1.0' }, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/license/, 'message names the missing field' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/check_manifest_completeness.t`
Expected: FAIL — module doesn't exist

- [ ] **Step 3: Write minimal implementation**

Create `lib/KohaPluginStore/Check/ManifestCompleteness.pm`:

```perl
package KohaPluginStore::Check::ManifestCompleteness;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;

sub check_name         { 'manifest_completeness' }
sub required            { 1 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @missing;
    push @missing, 'version' unless $metadata->{version};
    push @missing, 'license' unless $metadata->{license};

    return { passed => 1, message => undef } unless @missing;

    return {
        passed  => 0,
        message => 'Plugin metadata is missing required field(s): ' . join( ', ', @missing ),
    };
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/check_manifest_completeness.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Check/ManifestCompleteness.pm t/check_manifest_completeness.t
git commit -m "Add Check::ManifestCompleteness"
```

---

## Task 4: `Check::DependencyAllowlist` (required)

**Files:**
- Create: `lib/KohaPluginStore/Check/DependencyAllowlist.pm`
- Test: `t/check_dependency_allowlist.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Check::Base` (Task 2), including `$self->find_files($dir, $pattern)`.
- Produces: `KohaPluginStore::Check::DependencyAllowlist->new->run($extract_dir, $metadata, $context)`.

- [ ] **Step 1: Write the failing test**

Create `t/check_dependency_allowlist.t`:

```perl
use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::DependencyAllowlist;

subtest 'passes plain plugin code' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\nsub install { return 1 }\n1;\n" );

    my $check  = KohaPluginStore::Check::DependencyAllowlist->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails and names the file when system() is called' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\nsystem('rm -rf /tmp/x');\n1;\n" );

    my $check  = KohaPluginStore::Check::DependencyAllowlist->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/Widget\.pm/,    'message names the file' );
    like( $result->{message}, qr/system\(\)/,    'message names the pattern' );
};

subtest 'fails on filesystem access outside the plugin directory' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\nopen(my \$fh, '<', '../../etc/passwd');\n1;\n" );

    my $check  = KohaPluginStore::Check::DependencyAllowlist->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/check_dependency_allowlist.t`
Expected: FAIL — module doesn't exist

- [ ] **Step 3: Write minimal implementation**

Create `lib/KohaPluginStore/Check/DependencyAllowlist.pm`:

```perl
package KohaPluginStore::Check::DependencyAllowlist;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Slurp qw(read_file);

my @RISKY_PATTERNS = (
    [ qr/\bsystem\s*\(/,               'calls system()' ],
    [ qr/\bexec\s*\(/,                 'calls exec()' ],
    [ qr/`[^`]*`/,                     'uses backticks' ],
    [ qr/\bqx\s*[\(\{\[\/]/,           'uses qx//' ],
    [ qr/\buse\s+IO::Socket/,          'opens sockets (IO::Socket)' ],
    [ qr/\buse\s+Net::\w+/,            'uses a Net:: networking module' ],
    [ qr/\buse\s+(LWP|HTTP::Tiny)\b/,  'makes HTTP requests' ],
    [ qr/\bopen\s*\(.*['"]\s*\//,      'opens an absolute filesystem path' ],
    [ qr/\.\.\//,                      'references a path outside its own directory (../)' ],
);

sub check_name         { 'dependency_allowlist' }
sub required            { 1 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @issues;

    for my $file ( $self->find_files( $extract_dir, qr/\.(pm|pl)$/ ) ) {
        my $content  = read_file($file);
        my $relative = $file;
        $relative =~ s{^\Q$extract_dir\E/?}{};

        for my $pattern (@RISKY_PATTERNS) {
            my ( $re, $description ) = @$pattern;
            push @issues, "$relative: $description" if $content =~ $re;
        }
    }

    return { passed => 1, message => undef } unless @issues;
    return { passed => 0, message => join( '; ', @issues ) };
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/check_dependency_allowlist.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Check/DependencyAllowlist.pm t/check_dependency_allowlist.t
git commit -m "Add Check::DependencyAllowlist"
```

---

## Task 5: `Check::PerlSyntax` (required, sandboxed)

**Files:**
- Create: `lib/KohaPluginStore/Check/PerlSyntax.pm`
- Test: `t/check_perl_syntax.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Check::Base` (Task 2), including `$self->find_files($dir, $pattern)`. Reads `$context->{koha_checkout_cache_dir}` and `$context->{koha_git_url}` (both optional, with internal defaults) and `$metadata->{minimum_version}`.
- Produces: `KohaPluginStore::Check::PerlSyntax->new->run($extract_dir, $metadata, $context)`. Two test seams: `KohaPluginStore::Check::PerlSyntax::_ensure_checkout($tag, $checkout_dir)` (returns 1/0) and `KohaPluginStore::Check::PerlSyntax::_run_sandboxed($checkout_dir, $extract_dir, \@pm_files)` (returns raw `perl -c` output text). On infrastructure failure (checkout couldn't be prepared), `run()` dies with a message starting `check_infrastructure_error:` — callers (Task 14) must catch this specifically and map it to the `check_error` status, not a check failure.

**Note:** the exact Koha git tag naming convention (`_resolve_tag` below assumes `v<minimum_version>`, e.g. `v23.05.00`) needs confirming against a real `git ls-remote --tags` of Koha core before this is trusted in production — flagged in the design doc as a best-effort placeholder. The test seams mean this doesn't block testing the rest of the check's logic.

- [ ] **Step 1: Write the failing test**

Create `t/check_perl_syntax.t`:

```perl
use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::PerlSyntax;

subtest 'passes when the sandboxed perl -c reports syntax OK' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout = sub { return 1 };
    *KohaPluginStore::Check::PerlSyntax::_run_sandboxed   = sub { return "/plugin/Widget.pm syntax OK\n" };

    my $check  = KohaPluginStore::Check::PerlSyntax->new;
    my $result = $check->run( $dir, { minimum_version => '23.05' }, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails and reports the sandboxed compile error' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget\n1;\n" );    # missing semicolon

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout = sub { return 1 };
    *KohaPluginStore::Check::PerlSyntax::_run_sandboxed   = sub {
        return "syntax error at /plugin/Widget.pm line 2, near \"1;\"\n/plugin/Widget.pm had compilation errors.\n";
    };

    my $check  = KohaPluginStore::Check::PerlSyntax->new;
    my $result = $check->run( $dir, { minimum_version => '23.05' }, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/syntax error/, 'message includes the compile error' );
};

subtest 'a minimum_version that cannot be resolved to a tag fails clearly' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    my $check  = KohaPluginStore::Check::PerlSyntax->new;
    my $result = $check->run( $dir, { minimum_version => 'not-a-version' }, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/Could not resolve/, 'message explains why' );
};

subtest 'a checkout preparation failure dies as a check_infrastructure_error' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout = sub { return 0 };

    my $check = KohaPluginStore::Check::PerlSyntax->new;
    eval { $check->run( $dir, { minimum_version => '23.05' }, {} ) };
    like( $@, qr/^check_infrastructure_error/, 'dies with the infrastructure-error prefix' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/check_perl_syntax.t`
Expected: FAIL — module doesn't exist

- [ ] **Step 3: Write minimal implementation**

Create `lib/KohaPluginStore/Check/PerlSyntax.pm`:

```perl
package KohaPluginStore::Check::PerlSyntax;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Fcntl qw(:flock);

my $DEFAULT_CACHE_DIR = '/var/cache/koha-plugin-store/koha-checkouts';
my $DEFAULT_GIT_URL   = 'https://git.koha-community.org/Koha-community/Koha.git';

sub check_name         { 'perl_syntax' }
sub required            { 1 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my $tag = _resolve_tag( $metadata->{minimum_version} );
    unless ($tag) {
        return {
            passed  => 0,
            message => "Could not resolve a Koha release tag for minimum_version '"
                . ( $metadata->{minimum_version} // '' ) . "'",
        };
    }

    my $cache_dir     = $context->{koha_checkout_cache_dir} // $DEFAULT_CACHE_DIR;
    my $git_url       = $context->{koha_git_url}            // $DEFAULT_GIT_URL;
    my $checkout_dir  = "$cache_dir/$tag";

    unless ( _ensure_checkout( $tag, $checkout_dir, $git_url ) ) {
        die "check_infrastructure_error: could not prepare Koha checkout for tag $tag\n";
    }

    my @pm_files = $self->find_files( $extract_dir, qr/\.pm$/ );

    return { passed => 1, message => undef } unless @pm_files;

    my $output = _run_sandboxed( $checkout_dir, $extract_dir, \@pm_files );

    my @errors = grep { length && !/syntax OK$/ } split /\n/, $output;

    return { passed => 1, message => undef } unless @errors;
    return { passed => 0, message => join( '; ', @errors ) };
}

sub _resolve_tag {
    my ($minimum_version) = @_;
    return unless $minimum_version;
    return "v$minimum_version" if $minimum_version =~ /^\d+\.\d+(\.\d+)?$/;
    return;
}

# Test seam: overridden in tests to avoid a real git clone.
sub _ensure_checkout {
    my ( $tag, $checkout_dir, $git_url ) = @_;

    return 1 if -d $checkout_dir;

    make_path( dirname($checkout_dir) );
    my $lock_file = "$checkout_dir.lock";
    open my $lock_fh, '>', $lock_file or return 0;
    flock( $lock_fh, LOCK_EX );

    return 1 if -d $checkout_dir;    # another process won the race while we waited

    my $ok = system( 'git', 'clone', '--depth', '1', '--branch', $tag, $git_url, $checkout_dir ) == 0;

    close $lock_fh;
    unlink $lock_file;

    return $ok;
}

# Test seam: overridden in tests to avoid needing Docker.
#
# Wrapped in `timeout --signal=KILL` so a plugin file that hangs the compiler
# (e.g. an infinite BEGIN loop) can't tie up a Minion worker forever -- a
# timeout here is treated by run() as ordinary output (no "syntax OK" line
# survives it), so it fails PerlSyntax like any other compile error, not as a
# check_infrastructure_error. Known follow-up: a hard-killed `docker run`
# client can in rare cases leave the container itself running past the
# timeout since --rm only cleans up on normal exit; revisit with an explicit
# `docker kill` sweep if that's observed in practice.
sub _run_sandboxed {
    my ( $checkout_dir, $extract_dir, $pm_files ) = @_;

    my @relative = map { my $f = $_; $f =~ s{^\Q$extract_dir\E/?}{}; $f } @$pm_files;
    my $script   = join( '; ', map { qq{system('perl', '-I/koha/lib', '-cw', '/plugin/$_')} } @relative );

    return `timeout --signal=KILL 30 docker run --rm --network none --memory 256m --cpus 0.5 --read-only --tmpfs /tmp ` .
        `-v $checkout_dir:/koha:ro -v $extract_dir:/plugin:ro perl:5.38-slim ` .
        `perl -e '$script' 2>&1`;
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/check_perl_syntax.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Check/PerlSyntax.pm t/check_perl_syntax.t
git commit -m "Add Check::PerlSyntax with sandboxed perl -c"
```

---

## Task 6: `cpanfile` dependency + `Check::PerlCritic` (non-required, gating)

**Files:**
- Modify: `cpanfile`
- Create: `lib/KohaPluginStore/Check/PerlCritic.pm`
- Test: `t/check_perl_critic.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Check::Base` (Task 2), including `$self->find_files($dir, $pattern)`, and `Koha::QA::PerlCritic` (new dependency).
- Produces: `KohaPluginStore::Check::PerlCritic->new->run($extract_dir, $metadata, $context)`.

- [ ] **Step 1: Add the dependency**

Append to `cpanfile`:

```
requires 'Koha::QA', git => 'git@gitlab.com:joubu/koha-qa.git', ref => 'c98c2cd6ac14756fd82edc59655b54e11c8c9f31';
requires 'Perl::Critic';
requires 'File::ShareDir';
```

Run: `cpanm --installdeps .`
Expected: installs cleanly. Verify with: `perl -Ilib -MKoha::QA::PerlCritic -e 'print "ok\n"'` → prints `ok`.

- [ ] **Step 2: Write the failing test**

Create `t/check_perl_critic.t`:

```perl
use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::PerlCritic;

subtest 'passes a file with no policy violations' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\n1;\n" );

    my $check  = KohaPluginStore::Check::PerlCritic->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails a file missing strict/warnings' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    my $check  = KohaPluginStore::Check::PerlCritic->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
    ok( length $result->{message}, 'message has violation detail' );
};

done_testing();
```

- [ ] **Step 3: Run test to verify it fails**

Run: `prove -l t/check_perl_critic.t`
Expected: FAIL — module doesn't exist

- [ ] **Step 4: Write minimal implementation**

Create `lib/KohaPluginStore/Check/PerlCritic.pm`:

```perl
package KohaPluginStore::Check::PerlCritic;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use Koha::QA::PerlCritic;

sub check_name         { 'perl_critic' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @pm_files = $self->find_files( $extract_dir, qr/\.pm$/ );

    return { passed => 1, message => undef } unless @pm_files;

    my @violations;
    for my $file (@pm_files) {
        my $critic = Koha::QA::PerlCritic->new( { file => $file } );
        push @violations, map { $_->{message} } $critic->errors unless $critic->check;
    }

    return { passed => 1, message => undef } unless @violations;
    return { passed => 0, message => join( '; ', @violations ) };
}

1;
```

- [ ] **Step 5: Run test to verify it passes**

Run: `prove -l t/check_perl_critic.t`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add cpanfile lib/KohaPluginStore/Check/PerlCritic.pm t/check_perl_critic.t
git commit -m "Depend on Koha::QA and add Check::PerlCritic"
```

---

## Task 7: `Check::DocsPresence` (non-required, gating)

**Files:**
- Create: `lib/KohaPluginStore/Check/DocsPresence.pm`
- Test: `t/check_docs_presence.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Check::Base` (Task 2).
- Produces: `KohaPluginStore::Check::DocsPresence->new->run($extract_dir, $metadata, $context)`.

- [ ] **Step 1: Write the failing test**

Create `t/check_docs_presence.t`:

```perl
use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::DocsPresence;

subtest 'passes when Development.md is present' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Development.md", "# Development\n" );

    my $check  = KohaPluginStore::Check::DocsPresence->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'passes when README.md is present' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/README.md", "# Widget\n" );

    my $check  = KohaPluginStore::Check::DocsPresence->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails when nothing documents the plugin' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    my $check  = KohaPluginStore::Check::DocsPresence->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/check_docs_presence.t`
Expected: FAIL — module doesn't exist

- [ ] **Step 3: Write minimal implementation**

Create `lib/KohaPluginStore/Check/DocsPresence.pm`:

```perl
package KohaPluginStore::Check::DocsPresence;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;

my @ACCEPTABLE = qw(Development.md CONTRIBUTING.md README.md README docs);

sub check_name         { 'docs_presence' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    for my $name (@ACCEPTABLE) {
        return { passed => 1, message => undef } if -e "$extract_dir/$name";
    }

    return {
        passed  => 0,
        message => 'No Development.md, CONTRIBUTING.md, README, or docs/ directory found',
    };
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/check_docs_presence.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Check/DocsPresence.pm t/check_docs_presence.t
git commit -m "Add Check::DocsPresence"
```

---

## Task 8: `Check::TestsPresence` (non-required, gating)

**Files:**
- Create: `lib/KohaPluginStore/Check/TestsPresence.pm`
- Test: `t/check_tests_presence.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Check::Base` (Task 2), including `$self->find_files($dir, $pattern)`.
- Produces: `KohaPluginStore::Check::TestsPresence->new->run($extract_dir, $metadata, $context)`.

- [ ] **Step 1: Write the failing test**

Create `t/check_tests_presence.t`:

```perl
use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::TestsPresence;

subtest 'passes when t/ has at least one .t file' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/t");
    write_file( "$dir/t/basic.t", "use Test::More;\nok(1);\ndone_testing();\n" );

    my $check  = KohaPluginStore::Check::TestsPresence->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails when there is no t/ directory' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    my $check  = KohaPluginStore::Check::TestsPresence->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

subtest 'fails when t/ exists but is empty' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/t");

    my $check  = KohaPluginStore::Check::TestsPresence->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/check_tests_presence.t`
Expected: FAIL — module doesn't exist

- [ ] **Step 3: Write minimal implementation**

Create `lib/KohaPluginStore/Check/TestsPresence.pm`:

```perl
package KohaPluginStore::Check::TestsPresence;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;

sub check_name         { 'tests_presence' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @t_files = $self->find_files( "$extract_dir/t", qr/\.t$/ );

    return { passed => 1, message => undef } if @t_files;
    return { passed => 0, message => 'No test files (t/*.t) found' };
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/check_tests_presence.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Check/TestsPresence.pm t/check_tests_presence.t
git commit -m "Add Check::TestsPresence"
```

---

## Task 9: `Check::TranslatableTemplates` (non-required, gating)

**Files:**
- Create: `lib/KohaPluginStore/Check/TranslatableTemplates.pm`
- Test: `t/check_translatable_templates.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Check::Base` (Task 2), including `$self->find_files($dir, $pattern)`.
- Produces: `KohaPluginStore::Check::TranslatableTemplates->new->run($extract_dir, $metadata, $context)`.

- [ ] **Step 1: Write the failing test**

Create `t/check_translatable_templates.t`:

```perl
use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::TranslatableTemplates;

subtest 'passes a template that uses the t() translation marker' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/page.tt", "<h1>[% t('Hello') %]</h1>\n" );

    my $check  = KohaPluginStore::Check::TranslatableTemplates->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'passes when there are no templates at all' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    my $check  = KohaPluginStore::Check::TranslatableTemplates->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails a template that renders text but never calls t()' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/page.tt", "<h1>Hello there</h1>\n" );

    my $check  = KohaPluginStore::Check::TranslatableTemplates->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/page\.tt/, 'message names the file' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/check_translatable_templates.t`
Expected: FAIL — module doesn't exist

- [ ] **Step 3: Write minimal implementation**

Create `lib/KohaPluginStore/Check/TranslatableTemplates.pm`:

```perl
package KohaPluginStore::Check::TranslatableTemplates;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Slurp qw(read_file);

# Heuristic, not exhaustive: flags .tt files that render visible text but never
# call Koha's translation marker anywhere in the file. Doesn't inspect
# individual strings -- a file using t() even once is treated as translated.
sub check_name         { 'translatable_templates' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @untranslated;

    for my $file ( $self->find_files( $extract_dir, qr/\.tt$/ ) ) {
        my $content = read_file($file);
        next unless $content =~ /<(h1|h2|h3|p|label|button|span|td|th)\b/i;

        unless ( $content =~ /\[%[-~]?\s*t\s*\(/ ) {
            my $relative = $file;
            $relative =~ s{^\Q$extract_dir\E/?}{};
            push @untranslated, $relative;
        }
    }

    return { passed => 1, message => undef } unless @untranslated;

    return {
        passed  => 0,
        message => 'Template(s) render text but never use the [% t(...) %] translation marker: '
            . join( ', ', @untranslated ),
    };
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/check_translatable_templates.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Check/TranslatableTemplates.pm t/check_translatable_templates.t
git commit -m "Add Check::TranslatableTemplates"
```

---

## Task 10: `Check::PluginTemplateWrapper` (non-required, gating)

**Files:**
- Create: `lib/KohaPluginStore/Check/PluginTemplateWrapper.pm`
- Test: `t/check_plugin_template_wrapper.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Check::Base` (Task 2), including `$self->find_files($dir, $pattern)`.
- Produces: `KohaPluginStore::Check::PluginTemplateWrapper->new->run($extract_dir, $metadata, $context)`.

**Note:** `$REQUIRED_INCLUDE` below (`doc-head-close.inc`) is a best-effort placeholder for the real Koha plugin template wrapper include, pending confirmation against `Koha::Plugins` documentation or a real published plugin's templates — flagged in the design doc as unconfirmed. Update the constant, not the surrounding logic, once confirmed.

- [ ] **Step 1: Write the failing test**

Create `t/check_plugin_template_wrapper.t`:

```perl
use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::PluginTemplateWrapper;

subtest 'passes a template that includes the wrapper' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/page.tt", "[% INCLUDE 'doc-head-close.inc' %]\n<h1>Hello</h1>\n" );

    my $check  = KohaPluginStore::Check::PluginTemplateWrapper->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'passes when there are no templates at all' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    my $check  = KohaPluginStore::Check::PluginTemplateWrapper->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails a template missing the wrapper include' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/page.tt", "<h1>Hello</h1>\n" );

    my $check  = KohaPluginStore::Check::PluginTemplateWrapper->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/page\.tt/, 'message names the file' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/check_plugin_template_wrapper.t`
Expected: FAIL — module doesn't exist

- [ ] **Step 3: Write minimal implementation**

Create `lib/KohaPluginStore/Check/PluginTemplateWrapper.pm`:

```perl
package KohaPluginStore::Check::PluginTemplateWrapper;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Slurp qw(read_file);

# NOTE: the exact Koha plugin template wrapper include name below is a
# best-effort placeholder pending confirmation against Koha::Plugins
# documentation -- update this constant, not the surrounding logic, once
# confirmed.
my $REQUIRED_INCLUDE = 'doc-head-close.inc';

sub check_name         { 'plugin_template_wrapper' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @missing;

    for my $file ( $self->find_files( $extract_dir, qr/\.tt$/ ) ) {
        my $content = read_file($file);
        unless ( $content =~ /INCLUDE\s+['"]\Q$REQUIRED_INCLUDE\E['"]/ ) {
            my $relative = $file;
            $relative =~ s{^\Q$extract_dir\E/?}{};
            push @missing, $relative;
        }
    }

    return { passed => 1, message => undef } unless @missing;

    return {
        passed  => 0,
        message => "Template(s) missing the '$REQUIRED_INCLUDE' plugin wrapper include: " . join( ', ', @missing ),
    };
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/check_plugin_template_wrapper.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Check/PluginTemplateWrapper.pm t/check_plugin_template_wrapper.t
git commit -m "Add Check::PluginTemplateWrapper"
```

---

## Task 11: `Check::HardcodedCredentials` (non-required, gating)

**Files:**
- Create: `lib/KohaPluginStore/Check/HardcodedCredentials.pm`
- Test: `t/check_hardcoded_credentials.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Check::Base` (Task 2), including `$self->find_files($dir, $pattern)`.
- Produces: `KohaPluginStore::Check::HardcodedCredentials->new->run($extract_dir, $metadata, $context)`.

- [ ] **Step 1: Write the failing test**

Create `t/check_hardcoded_credentials.t`:

```perl
use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::HardcodedCredentials;

subtest 'passes plain plugin code' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\n1;\n" );

    my $check  = KohaPluginStore::Check::HardcodedCredentials->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails on a hardcoded password literal' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nmy \%opts = ( password => 'sup3rSecret!' );\n1;\n" );

    my $check  = KohaPluginStore::Check::HardcodedCredentials->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/Widget\.pm/, 'message names the file' );
};

subtest 'fails on an AWS-access-key-shaped string' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nmy \$key = 'AKIAABCDEFGHIJKLMNOP';\n1;\n" );

    my $check  = KohaPluginStore::Check::HardcodedCredentials->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/check_hardcoded_credentials.t`
Expected: FAIL — module doesn't exist

- [ ] **Step 3: Write minimal implementation**

Create `lib/KohaPluginStore/Check/HardcodedCredentials.pm`:

```perl
package KohaPluginStore::Check::HardcodedCredentials;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Slurp qw(read_file);

my @PATTERNS = (
    qr/\b(?:api[_-]?key|secret|token|password|passwd)\s*(?:=>|=)\s*['"][^'"]{6,}['"]/i,
    qr/-----BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY-----/,
    qr/\bAKIA[0-9A-Z]{16}\b/,    # AWS access key ID shape
);

sub check_name         { 'hardcoded_credentials' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @hits;

    for my $file ( $self->find_files( $extract_dir, qr/\.(pm|pl|tt)$/ ) ) {
        my $content = read_file($file);
        for my $pattern (@PATTERNS) {
            if ( $content =~ $pattern ) {
                my $relative = $file;
                $relative =~ s{^\Q$extract_dir\E/?}{};
                push @hits, $relative;
                last;
            }
        }
    }

    return { passed => 1, message => undef } unless @hits;
    return { passed => 0, message => 'Possible hardcoded credential(s) found in: ' . join( ', ', @hits ) };
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/check_hardcoded_credentials.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Check/HardcodedCredentials.pm t/check_hardcoded_credentials.t
git commit -m "Add Check::HardcodedCredentials"
```

---

## Task 12: `Check::KohaMaxVersion` (recorded, non-gating)

**Files:**
- Create: `lib/KohaPluginStore/Check/KohaMaxVersion.pm`
- Test: `t/check_koha_max_version.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Check::Base` (Task 2).
- Produces: `KohaPluginStore::Check::KohaMaxVersion->new->run($extract_dir, $metadata, $context)`. `gates_certification` is `0` — Task 14's tier computation must skip this check when deciding `STRUCTURAL` vs `CERTIFIED`.

- [ ] **Step 1: Write the failing test**

Create `t/check_koha_max_version.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::Check::KohaMaxVersion;

subtest 'passes when maximum_version is declared' => sub {
    my $check  = KohaPluginStore::Check::KohaMaxVersion->new;
    my $result = $check->run( '/unused', { maximum_version => '23.11' }, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails, but is non-gating, when maximum_version is missing' => sub {
    my $check  = KohaPluginStore::Check::KohaMaxVersion->new;
    my $result = $check->run( '/unused', {}, {} );
    ok( !$result->{passed}, 'failed' );
    ok( !$check->gates_certification, 'does not gate certification' );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/check_koha_max_version.t`
Expected: FAIL — module doesn't exist

- [ ] **Step 3: Write minimal implementation**

Create `lib/KohaPluginStore/Check/KohaMaxVersion.pm`:

```perl
package KohaPluginStore::Check::KohaMaxVersion;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;

sub check_name         { 'koha_max_version' }
sub required            { 0 }
sub gates_certification { 0 }

sub run ($self, $extract_dir, $metadata, $context) {
    return { passed => 1, message => undef } if $metadata->{maximum_version};
    return {
        passed  => 0,
        message => 'metadata does not declare maximum_version (recommended, does not block publishing)',
    };
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/check_koha_max_version.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Check/KohaMaxVersion.pm t/check_koha_max_version.t
git commit -m "Add Check::KohaMaxVersion"
```

---

## Task 13: `GitHub::fetch_tag_verification` + `Check::GpgSignedTag` (recorded, non-gating)

**Files:**
- Modify: `lib/KohaPluginStore/GitHub.pm`
- Modify: `t/github.t`
- Create: `lib/KohaPluginStore/Check/GpgSignedTag.pm`
- Test: `t/check_gpg_signed_tag.t`

**Interfaces:**
- Produces: `KohaPluginStore::GitHub::fetch_tag_verification($access_token, $owner_repo, $tag_name)` → `1`/`0`/`undef` (undef on a non-200 response, same degrade-gracefully convention as `fetch_releases`/`fetch_contributors`).
- Consumes (Check class): `KohaPluginStore::Check::Base` (Task 2), the new `fetch_tag_verification`. Reads `$context->{github_token}`, `$context->{repo_url}`, `$context->{tag_name}` (populated by Task 14).

- [ ] **Step 1: Write the failing test for `GitHub::fetch_tag_verification`**

Find the existing `_get` test-seam override pattern in `t/github.t` (e.g. how `fetch_releases` is tested) and add, following the same style:

```perl
subtest 'fetch_tag_verification returns whether the tag commit is GPG-verified' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my $tx = Mojo::Transaction::HTTP->new;
        $tx->res->code(200);
        $tx->res->body('{"commit":{"verification":{"verified":true}}}');
        $tx->res->headers->content_type('application/json');
        return $tx;
    };

    is( KohaPluginStore::GitHub::fetch_tag_verification( 'token', 'https://github.com/dev/widget', 'v1.0.0' ), 1, 'reports verified' );
};

subtest 'fetch_tag_verification returns undef on a non-200 response' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my $tx = Mojo::Transaction::HTTP->new;
        $tx->res->code(404);
        return $tx;
    };

    is( KohaPluginStore::GitHub::fetch_tag_verification( 'token', 'https://github.com/dev/widget', 'v1.0.0' ), undef, 'returns undef' );
};
```

(Check the top of `t/github.t` for however it already constructs a fake `Mojo::Transaction::HTTP` response for the other `_get`-mocking subtests, and match that exact style rather than the sketch above if it differs.)

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/github.t`
Expected: FAIL — `fetch_tag_verification` not defined

- [ ] **Step 3: Implement `fetch_tag_verification`**

Add to `lib/KohaPluginStore/GitHub.pm`, after `fetch_contributors`:

```perl
sub fetch_tag_verification {
    my ( $access_token, $owner_repo, $tag_name ) = @_;

    return unless $tag_name;

    my $api_repo = $owner_repo =~ s{^https://github\.com/}{https://api.github.com/repos/}r;
    my $tx = _get( "$api_repo/commits/$tag_name", $access_token );

    return unless $tx->result->code == 200;

    return $tx->result->json->{commit}{verification}{verified} ? 1 : 0;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/github.t`
Expected: PASS

- [ ] **Step 5: Write the failing test for `Check::GpgSignedTag`**

Create `t/check_gpg_signed_tag.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::Check::GpgSignedTag;

subtest 'passes when the tag is GPG-verified' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_tag_verification = sub { return 1 };

    my $check  = KohaPluginStore::Check::GpgSignedTag->new;
    my $result = $check->run( '/unused', {}, { github_token => 't', repo_url => 'https://github.com/dev/widget', tag_name => 'v1.0.0' } );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails, but is non-gating, when the tag is not verified' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_tag_verification = sub { return 0 };

    my $check  = KohaPluginStore::Check::GpgSignedTag->new;
    my $result = $check->run( '/unused', {}, { github_token => 't', repo_url => 'https://github.com/dev/widget', tag_name => 'v1.0.0' } );
    ok( !$result->{passed}, 'failed' );
    ok( !$check->gates_certification, 'does not gate certification' );
};

done_testing();
```

- [ ] **Step 6: Run test to verify it fails**

Run: `prove -l t/check_gpg_signed_tag.t`
Expected: FAIL — module doesn't exist

- [ ] **Step 7: Write minimal implementation**

Create `lib/KohaPluginStore/Check/GpgSignedTag.pm`:

```perl
package KohaPluginStore::Check::GpgSignedTag;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use KohaPluginStore::GitHub;

sub check_name         { 'gpg_signed_tag' }
sub required            { 0 }
sub gates_certification { 0 }

sub run ($self, $extract_dir, $metadata, $context) {
    my $verified = KohaPluginStore::GitHub::fetch_tag_verification(
        $context->{github_token}, $context->{repo_url}, $context->{tag_name}
    );

    return { passed => 1, message => undef } if $verified;
    return {
        passed  => 0,
        message => 'The release tag is not GPG-signed on GitHub (informational only, does not block publishing)',
    };
}

1;
```

- [ ] **Step 8: Run test to verify it passes**

Run: `prove -l t/check_gpg_signed_tag.t`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add lib/KohaPluginStore/GitHub.pm t/github.t lib/KohaPluginStore/Check/GpgSignedTag.pm t/check_gpg_signed_tag.t
git commit -m "Add fetch_tag_verification and Check::GpgSignedTag"
```

---

## Task 14: `KohaPluginStore::Checks` catalogue, `ProcessPluginVersion` wiring, `check_error` badge

**Files:**
- Create: `lib/KohaPluginStore/Checks.pm`
- Modify: `lib/KohaPluginStore/Task/ProcessPluginVersion.pm`
- Modify: `t/task_process_plugin_version.t`
- Modify: `templates/partial/table/plugins.html.ep`
- Modify: `t/plugins_listing.t`

**Interfaces:**
- Consumes: every `KohaPluginStore::Check::*` class from Tasks 2–13, `KohaPluginStore::Model::ReviewCheck` (Task 1).
- Produces: `@KohaPluginStore::Checks::ALL` (ordered list of check class names). `ProcessPluginVersion::run` now sets `plugin_versions.certification_tier` and can set `status = 'check_error'` in addition to the existing statuses.

- [ ] **Step 1: Create the check catalogue**

Create `lib/KohaPluginStore/Checks.pm`:

```perl
package KohaPluginStore::Checks;

use Modern::Perl;

use KohaPluginStore::Check::PerlSyntax;
use KohaPluginStore::Check::ManifestCompleteness;
use KohaPluginStore::Check::DependencyAllowlist;
use KohaPluginStore::Check::PerlCritic;
use KohaPluginStore::Check::DocsPresence;
use KohaPluginStore::Check::TestsPresence;
use KohaPluginStore::Check::TranslatableTemplates;
use KohaPluginStore::Check::PluginTemplateWrapper;
use KohaPluginStore::Check::HardcodedCredentials;
use KohaPluginStore::Check::KohaMaxVersion;
use KohaPluginStore::Check::GpgSignedTag;

our @ALL = qw(
    KohaPluginStore::Check::PerlSyntax
    KohaPluginStore::Check::ManifestCompleteness
    KohaPluginStore::Check::DependencyAllowlist
    KohaPluginStore::Check::PerlCritic
    KohaPluginStore::Check::DocsPresence
    KohaPluginStore::Check::TestsPresence
    KohaPluginStore::Check::TranslatableTemplates
    KohaPluginStore::Check::PluginTemplateWrapper
    KohaPluginStore::Check::HardcodedCredentials
    KohaPluginStore::Check::KohaMaxVersion
    KohaPluginStore::Check::GpgSignedTag
);

1;
```

- [ ] **Step 2: Write the failing task-level tests**

In `t/task_process_plugin_version.t`, add `use KohaPluginStore::Model::ReviewCheck;` to the `use` block near the top, and add this helper after the existing `make_kpz` sub (leave `make_kpz` itself untouched — existing subtests depend on its single-file-content signature):

```perl
sub make_multi_file_kpz {
    my ($files) = @_;
    my $dir      = tempdir( CLEANUP => 1 );
    my $zip_path = "$dir/fixture.kpz";
    my $zip      = Archive::Zip->new;
    $zip->addString( $files->{$_}, $_ ) for keys %$files;
    $zip->writeToFileNamed($zip_path);
    return $zip_path;
}
```

Then add these four subtests before `done_testing();`:

```perl
subtest 'a fully compliant version reaches CERTIFIED' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_multi_file_kpz(
        {
            'Widget.pm' => <<'PERL',
package Widget;
use Modern::Perl;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name            => 'Widget',
    description     => 'A test widget',
    author          => 'Someone',
    minimum_version => '23.05',
    maximum_version => '23.11',
    version         => '1.0.0',
    license         => 'GPL-3.0',
};
1;
PERL
            'Development.md'   => "# Development\n",
            't/basic.t'         => "use Test::More;\nok(1);\ndone_testing();\n",
            'templates/page.tt' => "[% INCLUDE 'doc-head-close.inc' %]\n<h1>[% t('Hello') %]</h1>\n",
        }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors           = sub { return [] };
    *KohaPluginStore::GitHub::fetch_tag_verification       = sub { return 0 };
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout  = sub { return 1 };
    *KohaPluginStore::Check::PerlSyntax::_run_sandboxed    = sub { return "syntax OK\n" };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is published' );
    is( $reloaded->certification_tier, 'CERTIFIED', 'certification_tier is CERTIFIED' );

    my @checks = KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->search( { plugin_version_id => $version->id } );
    is( scalar @checks, 11, 'a review_checks row was recorded for every check' );
    is( scalar( grep { $_->passed } @checks ), 10, 'every check passed except the non-gating GPG signature check' );
};

subtest 'passing only required checks reaches STRUCTURAL' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_multi_file_kpz(
        {
            'Widget.pm' => <<'PERL',
package Widget;
use Modern::Perl;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name            => 'Widget',
    description     => 'A test widget',
    author          => 'Someone',
    minimum_version => '23.05',
    version         => '1.0.0',
    license         => 'GPL-3.0',
};
1;
PERL
        }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors           = sub { return [] };
    *KohaPluginStore::GitHub::fetch_tag_verification       = sub { return 0 };
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout  = sub { return 1 };
    *KohaPluginStore::Check::PerlSyntax::_run_sandboxed    = sub { return "syntax OK\n" };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is published' );
    is( $reloaded->certification_tier, 'STRUCTURAL', 'certification_tier is STRUCTURAL, not CERTIFIED' );
};

subtest 'failing a required check reaches INCOMPLETE and never publishes' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_multi_file_kpz(
        {
            'Widget.pm' => <<'PERL',
package Widget;
use Modern::Perl;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name            => 'Widget',
    description     => 'A test widget',
    author          => 'Someone',
    minimum_version => '23.05',
    version         => '1.0.0',
};
1;
PERL
        }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors           = sub { return [] };
    *KohaPluginStore::GitHub::fetch_tag_verification       = sub { return 0 };
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout  = sub { return 1 };
    *KohaPluginStore::Check::PerlSyntax::_run_sandboxed    = sub { return "syntax OK\n" };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'changes_requested', 'status is changes_requested' );
    is( $reloaded->certification_tier, 'INCOMPLETE', 'certification_tier is INCOMPLETE' );

    my $manifest_check = KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->find(
        { plugin_version_id => $version->id, check_name => 'manifest_completeness' }
    );
    ok( !$manifest_check->passed, 'the manifest_completeness check row records the failure' );
};

subtest 'a sandbox infrastructure failure sets check_error, not changes_requested' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_multi_file_kpz(
        {
            'Widget.pm' => <<'PERL',
package Widget;
use Modern::Perl;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name            => 'Widget',
    description     => 'A test widget',
    author          => 'Someone',
    minimum_version => '23.05',
    version         => '1.0.0',
    license         => 'GPL-3.0',
};
1;
PERL
        }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors          = sub { return [] };
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout = sub { return 0 };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'check_error', 'status is check_error, not changes_requested' );
};
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `prove -l t/task_process_plugin_version.t`
Expected: FAIL — `certification_tier` never gets set, `check_error` status doesn't exist yet, `KohaPluginStore::Checks` doesn't exist

- [ ] **Step 4: Wire the checks into `ProcessPluginVersion`**

In `lib/KohaPluginStore/Task/ProcessPluginVersion.pm`, add near the top with the other `use` statements:

```perl
use KohaPluginStore::Checks;
use KohaPluginStore::Model::ReviewCheck;
```

Replace the existing tail of `run` — everything from the `my $digest = do { ... };` block through the final `$version->update(...)` call — with:

```perl
    my $digest = do {
        open my $fh, '<:raw', $kpz_path or die "Could not open $kpz_path: $!";
        local $/;
        sha256_hex(<$fh>);
    };

    $plugin->update(
        {
            name        => $metadata->{name},
            description => $metadata->{description},
            author      => $metadata->{author},
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

    my $check_context = {
        repo_url     => $plugin->repo_url,
        tag_name     => $version->tag_name,
        github_token => $token,
    };

    my $review_check_model = KohaPluginStore::Model::ReviewCheck->new( pg => $app->pg );
    my $required_failed;
    my $gating_failed;

    for my $check_class (@KohaPluginStore::Checks::ALL) {
        my $check  = $check_class->new;
        my $result = eval { $check->run( $extract_dir, $metadata, $check_context ) };
        if ($@) {
            if ( $@ =~ /^check_infrastructure_error/ ) {
                return $version->update( { status => 'check_error', error_message => "$check_class: $@" } );
            }
            die $@;
        }

        $review_check_model->record(
            {
                plugin_version_id => $version->id,
                check_name        => $check->check_name,
                required          => $check->required,
                passed            => $result->{passed},
                message           => $result->{message},
            }
        );

        if ( !$result->{passed} ) {
            $required_failed = 1 if $check->required;
            $gating_failed   = 1 if $check->gates_certification;
        }
    }

    if ($required_failed) {
        return $version->update(
            {
                status             => 'changes_requested',
                certification_tier => 'INCOMPLETE',
                error_message      => 'One or more required checks failed -- see the version page for details.',
            }
        );
    }

    $version->update(
        {
            status             => 'published',
            content_digest     => $digest,
            version            => $metadata->{version},
            koha_min_version   => $metadata->{minimum_version},
            certification_tier => $gating_failed ? 'STRUCTURAL' : 'CERTIFIED',
        }
    );
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `prove -l t/task_process_plugin_version.t`
Expected: PASS

- [ ] **Step 6: Add the `check_error` badge**

In `templates/partial/table/plugins.html.ep`, change:

```
% my %status_badge = (
%   submitted          => 'bg-secondary',
%   checks_running     => 'bg-info',
%   published          => 'bg-success',
%   changes_requested  => 'bg-danger',
% );
```

to:

```
% my %status_badge = (
%   submitted          => 'bg-secondary',
%   checks_running     => 'bg-info',
%   published          => 'bg-success',
%   changes_requested  => 'bg-danger',
%   check_error        => 'bg-warning',
% );
```

- [ ] **Step 7: Write the failing test for the badge**

In `t/plugins_listing.t`, add this subtest before `done_testing();`:

```perl
subtest 'a version stuck in check_error shows its own badge' => sub {
    reset_db();
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'dev' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $developer->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )
      ->create( { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'check_error' } );

    $t->get_ok('/plugins')
      ->status_is(200)
      ->element_exists('td.plugin-status span.bg-warning')
      ->text_like( 'td.plugin-status span' => qr/check_error/ );
};
```

- [ ] **Step 8: Run test to verify it fails, then passes**

Run: `prove -l t/plugins_listing.t`
Expected: FAIL before Step 6's template edit is in place, PASS after (Step 6 is already done above, so this should already pass — run it to confirm).

- [ ] **Step 9: Run the full suite**

Run: `prove -l t/`
Expected: PASS — every existing test plus every new one from this plan.

- [ ] **Step 10: Commit**

```bash
git add lib/KohaPluginStore/Checks.pm lib/KohaPluginStore/Task/ProcessPluginVersion.pm t/task_process_plugin_version.t templates/partial/table/plugins.html.ep t/plugins_listing.t
git commit -m "Wire the check pipeline into ProcessPluginVersion and add the check_error badge"
```

---

## After all tasks: worktree, rebase, and PR

This work lands on a new worktree/branch stacked on the existing chain (currently #15 `developer-oauth-login` → #18 `repo-picker` → #19 `submission-pipeline` → #20 `home-page-rework`). Per this project's established pattern:

- [ ] Create a new worktree/branch (e.g. `worktree-check-pipeline`) stacked on top of `worktree-home-page-rework` (the current tip of the chain), via the `superpowers:using-git-worktrees` skill.
- [ ] Confirm with the user which branch this should stack on before creating it — the chain's tip may have moved since this plan was written.
- [ ] After all 14 tasks are committed, run the full test suite once more (`prove -l t/`) against a fresh migrated test database to catch any migration-ordering issues.
- [ ] Push to both `martin` and `origin` remotes (per this session's established convention: any branch that could become another PR's base needs to exist on `origin`, not just the fork).
- [ ] Open a PR stacked on `worktree-home-page-rework` (#20).
