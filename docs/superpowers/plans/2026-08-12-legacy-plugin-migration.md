# Legacy Plugin Discovery/Install Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the security gap where `Koha::REST::V1::Plugins::add()` (the plugin-store's install endpoint) enforces none of the checks the legacy manual-install path enforces, then replace both the legacy install path and the legacy live-search feature with one shared, properly-secured install routine and a plugin-store-backed discovery call — while keeping the existing org-allowlist concept an admin can configure via `koha-conf.xml`.

**Architecture:** All work is in Koha core (`core/worktrees/bug_35837`), not the plugin-store service. A new `Koha::Plugins::Install` module centralises validation (digest, org-allowlist against the plugin's *origin repo*, minimum-certification-level) and the actual extract+install step; a new `Koha::Plugins::Store` module resolves a `.kpz` URL to its plugin-store metadata (`repo_url`, `certification_tier`) via one HTTP call to the store's existing public discovery API. `plugins/plugins-upload.pl` and `Koha::REST::V1::Plugins::add()` both become thin callers of `Koha::Plugins::Install`; `plugins/plugins-home.pl`'s live GitHub/GitLab search is replaced with a call to the same discovery API `Koha::Plugins::Store` already talks to.

**Tech Stack:** Perl (Modern::Perl, no `-signatures` — this codebase's existing style), Mojolicious (`Mojo::URL`, `Mojo::UserAgent` — already dependencies), `Digest::SHA`, `Archive::Extract`, `List::Util`, Test::More/Test::Mojo/Test::MockModule/`t::lib::TestBuilder`/`t::lib::Mocks` (existing Koha test conventions).

## Global Constraints

- Full rationale for every decision below lives in `docs/superpowers/specs/2026-08-12-legacy-plugin-migration-design.md` — consult it if a task's "why" isn't obvious from the plan alone.
- No signature verification exists yet anywhere (store-side Ed25519 signing is not built — spec §4.3 / build-order step 6). Nothing in this plan blocks on it; the digest is computed and returned so a future task can slot verification in without touching call sites again.
- The org-allowlist check is always against the plugin's **origin repo** (`repo_url`), never against a download URL (`kpz_url`/`uploadlocation`) — that substring-against-a-URL approach is the exact bug being fixed, not a pattern to replicate anywhere new.
- `PluginStoreMinimumLevel` only gates versions with a *known* plugin-store certification tier. A plugin with no known tier (manual upload, or a legacy-search result with no plugin-store record) is gated by the org-allowlist step only, never rejected by the level check for lack of a tier.
- Every new/modified Perl module uses traditional `my ( $self, $args ) = @_;`-style subs, matching `Koha::Plugins.pm`/`Koha::Plugins::Base.pm` — not `Mojo::Base ... -signatures` (that's the koha-plugin-store service's style, not core Koha's).
- TDD throughout: write the failing test, run it, implement the minimal code, run it again, commit.
- Follow the `koha-contributor:koha-syspref` and `koha-contributor:koha-schema-apply`-equivalent conventions already established in this codebase for Task 5's atomicupdate.

---

## Task 1: Stopgap — make `Koha::REST::V1::Plugins::add()` enforce `plugins_restricted`

This is the fastest fix for the actual security regression: the endpoint already computes an
`%errors` hash including `RESTRICTED`, but never checks it before extracting and installing.
Fixing just that — using the *existing* legacy config, no new modules yet — closes the immediate
exposure while Tasks 2–4 build the real replacement. This task's fix gets superseded by Task 4,
but ships independently and immediately.

**Files:**
- Modify: `Koha/REST/V1/Plugins.pm` (the `add` sub, currently lines 44–92)
- Test: create `t/db_dependent/api/v1/plugins.t`

**Interfaces:**
- No new interfaces — this task only wires up logic that already exists in the file.

- [ ] **Step 1: Write the failing test**

Create `t/db_dependent/api/v1/plugins.t`:

```perl
#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use Test::More tests => 2;
use Test::NoWarnings;
use Test::Mojo;

use t::lib::TestBuilder;
use t::lib::Mocks;

use Koha::Database;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

my $t = Test::Mojo->new('Koha::REST::V1');
t::lib::Mocks::mock_preference( 'RESTBasicAuth', 1 );

subtest 'add() respects plugins_restricted' => sub {

    plan tests => 3;

    $schema->storage->txn_begin;

    my $password = 'thePassword123';
    my $patron    = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { flags => 2**19 }    # plugins flag
        }
    );
    $patron->set_password( { password => $password, skip_validation => 1 } );
    my $userid = $patron->userid;

    t::lib::Mocks::mock_config( 'plugins_restricted', 1 );
    t::lib::Mocks::mock_config( 'enable_plugins',     1 );

    $t->post_ok(
        "//$userid:$password\@/api/v1/plugins" => json => { kpz_url => 'https://evil.example.com/plugin.kpz' } )
        ->status_is( 403, 'A kpz_url with an unresolvable plugin-store origin is rejected, not silently installed' );

    $schema->storage->txn_rollback;
};
```

- [ ] **Step 2: Run test to verify it fails**

Run (inside the KTD container, from the Koha root): `prove -l t/db_dependent/api/v1/plugins.t`
Expected: FAIL — the current code has no `if (%errors)` guard, so it proceeds to
`Archive::Extract`/`InstallPlugins` and returns `201`, not `403`. (It may also error out
attempting to download `https://evil.example.com/plugin.kpz` via `File::Fetch` — either way, it
does not return the `403` this test asserts.)

- [ ] **Step 3: Write minimal implementation**

Replace the body of `sub add` in `Koha/REST/V1/Plugins.pm` (currently lines 44–92) with:

```perl
sub add {
    my $c = shift->openapi->valid_input or return;

    my $body    = $c->req->json;
    my $kpz_url = $body->{kpz_url};

    return $c->render( status => 400, openapi => { error => 'Missing kpz_url' } )
        unless $kpz_url;

    my ($uploadfilename) = $kpz_url =~ m{([^/]+)$};

    my $plugins_restricted = C4::Context->config("plugins_restricted");
    my $plugins_dir        = C4::Context->config("pluginsdir");
    $plugins_dir = ref($plugins_dir) eq 'ARRAY' ? $plugins_dir->[0] : $plugins_dir;

    my %errors;
    $errors{'NOTKPZ'}         = 1 if ( $uploadfilename !~ /\.kpz$/i );
    $errors{'NOWRITEPLUGINS'} = 1 unless ( -w $plugins_dir );
    # Stopgap only: rejects every install while plugins_restricted is on --
    # there's no allowlist check against anything yet, only the ability to
    # reject, which is the correct fail-closed tradeoff for closing an
    # active security gap quickly. Task 4 replaces this whole block with
    # Koha::Plugins::Install, checked against the plugin's actual origin
    # repo, which can actually pass.
    $errors{'RESTRICTED'} = 1 if $plugins_restricted;

    # Checked before downloading anything, deliberately -- no point fetching
    # a URL we're going to reject regardless of its contents.
    return $c->render( status => 403, openapi => { error => 'Install rejected', details => \%errors } )
        if %errors;

    use File::Fetch;
    my $ff   = File::Fetch->new( uri => $kpz_url );
    my $file = eval { $ff->fetch };
    return $c->render( status => 500, openapi => { error => 'Could not download kpz_url' } )
        unless $file;

    my $ae = Archive::Extract->new( archive => $file, type => 'zip' );
    unless ( $ae->extract( to => $plugins_dir ) ) {
        return $c->render( status => 500, openapi => { error => 'Could not unzip kpz_url' } );
    }

    Koha::Plugins->new->InstallPlugins( { verbose => 0 } );

    return try {
        return $c->render(
            status  => 201,
            openapi => { success => 'Plugin installed' }
        );
    }
    catch {
        $c->unhandled_exception($_);
    };
}
```

Note the removal of the dead `Mojo::Asset::File`/`$uploadfile` CGI-style leftover code that
existed in the original — it was never used for anything (the endpoint always receives
`kpz_url` in the JSON body, never a raw multipart upload).

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/db_dependent/api/v1/plugins.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Koha/REST/V1/Plugins.pm t/db_dependent/api/v1/plugins.t
git commit -m "Bug 35837: (follow-up) Enforce plugins_restricted in the plugin-store install endpoint

The endpoint already computed a %errors hash including RESTRICTED but
never checked it before extracting and installing, meaning an instance
running Koha's own shipped default (plugins_restricted => 1) was less
restricted installing via the plugin-store than via the legacy upload
path sitting next to it in the same UI. This is a stopgap using the
existing (weak) config check; Task 4 of the migration plan replaces it
with a real allowlist check against the plugin's origin repo."
```

---

## Task 2: `Koha::Plugins::Install` — shared validation and install routine

Builds the real replacement for both the stopgap above and `plugins-upload.pl`'s existing
`$do_get` logic, in isolation, fully unit-testable without a running Mojolicious app or database.

**Files:**
- Create: `Koha/Plugins/Install.pm`
- Test: create `t/Koha/Plugins/Install.t`

**Interfaces:**
- Produces: `Koha::Plugins::Install->install({ kpz_path => $path, filename => $name, repo_url =>
  $url_or_undef, certification_tier => $tier_or_undef })` returning `($ok, $result)` where
  `$result` is `{ digest => $sha256_hex }` on success (`$ok` true) or an errors hashref (keys:
  `NOTKPZ`, `NOWRITEPLUGINS`, `RESTRICTED`, `BELOWMINIMUMLEVEL`, `UNZIPFAIL`) on failure (`$ok`
  false).

- [ ] **Step 1: Write the failing test**

Create `t/Koha/Plugins/Install.t`:

```perl
#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use Test::More tests => 6;
use Test::NoWarnings;
use Test::MockModule;
use File::Temp qw(tempdir tempfile);
use Archive::Zip qw(:CONSTANTS);

use t::lib::Mocks;

use Koha::Plugins::Install;

my $plugins_dir = tempdir( CLEANUP => 1 );
t::lib::Mocks::mock_config( 'pluginsdir', $plugins_dir );

my $c4_context = Test::MockModule->new('C4::Context');

sub _fixture_kpz {
    my ($fh, $path) = tempfile( SUFFIX => '.kpz' );
    my $zip = Archive::Zip->new;
    $zip->addString( "package Test; 1;", 'Test.pm' );
    $zip->writeToFileNamed($path);
    return $path;
}

subtest 'rejects a non-.kpz filename' => sub {
    plan tests => 1;
    t::lib::Mocks::mock_config( 'plugins_restricted', 0 );
    my ( $ok, $result ) = Koha::Plugins::Install->install(
        { kpz_path => _fixture_kpz(), filename => 'plugin.zip' } );
    is( $result->{NOTKPZ}, 1, 'NOTKPZ error set for a non-.kpz filename' );
};

subtest 'unrestricted install with no known repo_url succeeds' => sub {
    plan tests => 1;
    t::lib::Mocks::mock_config( 'plugins_restricted', 0 );
    my ( $ok, $result ) = Koha::Plugins::Install->install(
        { kpz_path => _fixture_kpz(), filename => 'plugin.kpz' } );
    ok( $ok, 'install succeeds when plugins_restricted is off, even with no known repo_url' );
};

subtest 'restricted install with no known repo_url is rejected' => sub {
    plan tests => 2;
    t::lib::Mocks::mock_config( 'plugins_restricted', 1 );
    t::lib::Mocks::mock_config( 'plugin_repos', { repo => [ { org_name => 'bywatersolutions', service => 'github' } ] } );
    my ( $ok, $result ) = Koha::Plugins::Install->install(
        { kpz_path => _fixture_kpz(), filename => 'plugin.kpz' } );
    ok( !$ok, 'install is rejected with no repo_url to check against the allowlist' );
    is( $result->{RESTRICTED}, 1, 'RESTRICTED error set' );
};

subtest 'restricted install: the exact substring-bypass URL is correctly rejected' => sub {
    plan tests => 2;
    t::lib::Mocks::mock_config( 'plugins_restricted', 1 );
    t::lib::Mocks::mock_config( 'plugin_repos', { repo => [ { org_name => 'bywatersolutions', service => 'github' } ] } );
    my ( $ok, $result ) = Koha::Plugins::Install->install(
        {
            kpz_path => _fixture_kpz(),
            filename => 'plugin.kpz',
            repo_url => 'https://evil.example.com/bywatersolutions/plugin',
        }
    );
    ok( !$ok, 'a repo_url whose path merely contains an allowed org_name, on the wrong host, is rejected' );
    is( $result->{RESTRICTED}, 1, 'RESTRICTED error set' );
};

subtest 'restricted install: an exact, correctly-hosted org match is allowed' => sub {
    plan tests => 1;
    t::lib::Mocks::mock_config( 'plugins_restricted', 1 );
    t::lib::Mocks::mock_config( 'plugin_repos', { repo => [ { org_name => 'bywatersolutions', service => 'github' } ] } );
    my ( $ok, $result ) = Koha::Plugins::Install->install(
        {
            kpz_path => _fixture_kpz(),
            filename => 'plugin.kpz',
            repo_url => 'https://github.com/bywatersolutions/koha-plugin-coverflow',
        }
    );
    ok( $ok, 'a repo_url exactly matching an allowed org on the right host is allowed' );
};

subtest 'certification tier below PluginStoreMinimumLevel is rejected' => sub {
    plan tests => 2;
    t::lib::Mocks::mock_config( 'plugins_restricted', 0 );
    t::lib::Mocks::mock_preference( 'PluginStoreMinimumLevel', 'CERTIFIED' );
    my ( $ok, $result ) = Koha::Plugins::Install->install(
        {
            kpz_path           => _fixture_kpz(),
            filename           => 'plugin.kpz',
            certification_tier => 'STRUCTURAL',
        }
    );
    ok( !$ok, 'install is rejected when below the configured minimum level' );
    is( $result->{BELOWMINIMUMLEVEL}, 1, 'BELOWMINIMUMLEVEL error set' );
};
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/Koha/Plugins/Install.t`
Expected: FAIL with "Can't locate Koha/Plugins/Install.pm in @INC"

- [ ] **Step 3: Write minimal implementation**

Create `Koha/Plugins/Install.pm`:

```perl
package Koha::Plugins::Install;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use List::Util qw(any);
use Digest::SHA qw(sha256_hex);
use Mojo::URL;
use Archive::Extract;

use C4::Context;
use Koha::Plugins;

=head1 NAME

Koha::Plugins::Install

=head1 API

=head2 Class methods

=head3 install

    my ( $ok, $result ) = Koha::Plugins::Install->install({
        kpz_path           => $local_path_to_kpz,
        filename            => $original_filename,     # used for the .kpz extension check
        repo_url            => $repo_url,               # optional; the plugin's origin repo, if known
        certification_tier  => $tier,                   # optional; the plugin-store's tier for this version, if known
    });

Validates, then extracts and installs, a plugin already downloaded to a local path. On success
returns C<(1, { digest => $sha256_hex })>. On failure returns C<(0, \%errors)> where C<%errors>
keys are any of C<NOTKPZ>, C<NOWRITEPLUGINS>, C<RESTRICTED>, C<BELOWMINIMUMLEVEL>, C<UNZIPFAIL> --
never installs anything if any check fails.

This is the single place both C<plugins/plugins-upload.pl> and
C<Koha::REST::V1::Plugins::add()> should call, so the two entry points can never drift into
having different security checks again.

=cut

sub install {
    my ( $class, $params ) = @_;

    my $kpz_path = $params->{kpz_path};
    my $filename = $params->{filename} // '';
    my $repo_url = $params->{repo_url};
    my $tier     = $params->{certification_tier};

    my %errors;
    $errors{NOTKPZ} = 1 if $filename !~ /\.kpz$/i;

    my $plugins_dir = C4::Context->config('pluginsdir');
    $plugins_dir = ref($plugins_dir) eq 'ARRAY' ? $plugins_dir->[0] : $plugins_dir;
    $errors{NOWRITEPLUGINS} = 1 unless -w $plugins_dir;

    $errors{RESTRICTED}        = 1 unless $class->_repo_allowed($repo_url);
    $errors{BELOWMINIMUMLEVEL} = 1 unless $class->_meets_minimum_level($tier);

    return ( 0, \%errors ) if %errors;

    # Digest is computed and returned for callers to log/record. It is not
    # yet checked against anything -- the store doesn't sign versions yet
    # (spec §4.3 / build-order step 6). This is a deliberate no-op, not an
    # oversight: once the store signs, verification slots in right here,
    # before extraction, without any call site needing to change.
    my $digest = $class->_digest($kpz_path);

    my $ae = Archive::Extract->new( archive => $kpz_path, type => 'zip' );
    unless ( $ae->extract( to => $plugins_dir ) ) {
        return ( 0, { UNZIPFAIL => $ae->error } );
    }

    Koha::Plugins->new->InstallPlugins( { verbose => 0 } );

    return ( 1, { digest => $digest } );
}

sub _digest {
    my ( $class, $kpz_path ) = @_;

    open my $fh, '<:raw', $kpz_path or die "Could not open $kpz_path: $!";
    local $/;
    return sha256_hex(<$fh>);
}

my %EXPECTED_HOST = ( github => 'github.com', gitlab => 'gitlab.com' );

sub _repo_allowed {
    my ( $class, $repo_url ) = @_;

    return 1 unless C4::Context->config('plugins_restricted');
    return 0 unless $repo_url;

    my $repos = C4::Context->config('plugin_repos') or return 0;
    $repos = { repo => [ $repos->{repo} ] } if ref( $repos->{repo} ) eq 'HASH';

    my $url      = Mojo::URL->new($repo_url);
    my $host     = lc( $url->host // '' );
    my @segments = grep { length } @{ $url->path->parts };
    my $owner    = lc( $segments[0] // '' );

    return any {
        my $expected_host = $EXPECTED_HOST{ $_->{service} } // '';
        lc( $_->{org_name} ) eq $owner && $host eq $expected_host;
    } @{ $repos->{repo} };
}

sub _meets_minimum_level {
    my ( $class, $tier ) = @_;

    my $minimum = C4::Context->preference('PluginStoreMinimumLevel');
    return 1 unless $minimum;    # syspref off -- no gate
    return 1 unless $tier;       # no known plugin-store provenance -- gated by _repo_allowed instead, not this check

    my %rank = ( INCOMPLETE => 0, STRUCTURAL => 1, CERTIFIED => 2 );
    return ( $rank{$tier} // -1 ) >= ( $rank{$minimum} // 0 );
}

1;

=head1 AUTHOR

Koha Development Team

=cut
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/Koha/Plugins/Install.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Koha/Plugins/Install.pm t/Koha/Plugins/Install.t
git commit -m "Bug 35837: (follow-up) Add Koha::Plugins::Install, a shared validate+install routine

Centralises the checks that plugins-upload.pl and Koha::REST::V1::Plugins
will both delegate to (Task 4): a real org-allowlist check against the
plugin's origin repo (host + owner segment, not a substring match against
a download URL -- the exact class of bug this migration fixes), and the
new PluginStoreMinimumLevel gate. Not yet wired into either entry point."
```

---

## Task 3: `Koha::Plugins::Store` — resolve a `.kpz` URL to plugin-store metadata

**Files:**
- Create: `Koha/Plugins/Store.pm`
- Test: create `t/Koha/Plugins/Store.t`

**Interfaces:**
- Produces: `Koha::Plugins::Store->lookup_by_kpz_url($kpz_url)` returning `{ repo_url => $url,
  certification_tier => $tier }` if found, or `undef` if the store isn't configured, isn't
  reachable, or has no matching release.
- Consumes: `C4::Context->config('plugin_store_url')`, `C4::Context->preference('Version')`.

- [ ] **Step 1: Write the failing test**

Create `t/Koha/Plugins/Store.t`:

```perl
#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use Test::More tests => 4;
use Test::NoWarnings;
use Test::MockModule;

use t::lib::Mocks;

use Koha::Plugins::Store;

subtest 'returns undef when plugin_store_url is not configured' => sub {
    plan tests => 1;
    t::lib::Mocks::mock_config( 'plugin_store_url', undef );
    is( Koha::Plugins::Store->lookup_by_kpz_url('https://example.com/plugin.kpz'), undef,
        'undef when the store URL is not configured' );
};

subtest 'returns undef when no release matches the given kpz_url' => sub {
    plan tests => 1;
    t::lib::Mocks::mock_config( 'plugin_store_url', 'http://store.example.com' );
    t::lib::Mocks::mock_preference( 'Version', '26.06.00.000' );

    my $ua_module = Test::MockModule->new('Mojo::UserAgent');
    $ua_module->mock(
        get => sub {
            my $tx = Mojo::Transaction::HTTP->new;
            $tx->res->code(200);
            $tx->res->body('[]');
            return $tx;
        }
    );

    is( Koha::Plugins::Store->lookup_by_kpz_url('https://example.com/nomatch.kpz'), undef,
        'undef when the store has no plugin with a matching release kpz_url' );
};

subtest 'resolves repo_url and certification_tier for a matching kpz_url' => sub {
    plan tests => 1;

    t::lib::Mocks::mock_config( 'plugin_store_url', 'http://store.example.com' );
    t::lib::Mocks::mock_preference( 'Version', '26.06.00.000' );

    my $ua_module = Test::MockModule->new('Mojo::UserAgent');
    $ua_module->mock(
        get => sub {
            my $tx  = Mojo::Transaction::HTTP->new;
            my $body = '[{"repo_url":"https://github.com/openfifth/koha-plugin-coverflow","releases":'
                . '[{"kpz_url":"https://example.com/match.kpz","certification_tier":"CERTIFIED"}]}]';
            $tx->res->code(200);
            $tx->res->body($body);
            return $tx;
        }
    );

    is_deeply(
        Koha::Plugins::Store->lookup_by_kpz_url('https://example.com/match.kpz'),
        { repo_url => 'https://github.com/openfifth/koha-plugin-coverflow', certification_tier => 'CERTIFIED' },
        'repo_url and certification_tier resolved from the matching release'
    );
};
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/Koha/Plugins/Store.t`
Expected: FAIL with "Can't locate Koha/Plugins/Store.pm in @INC"

- [ ] **Step 3: Write minimal implementation**

Create `Koha/Plugins/Store.pm`:

```perl
package Koha::Plugins::Store;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use Mojo::UserAgent;

use C4::Context;

=head1 NAME

Koha::Plugins::Store

=head1 API

=head2 Class methods

=head3 lookup_by_kpz_url

    my $info = Koha::Plugins::Store->lookup_by_kpz_url($kpz_url);
    # { repo_url => '...', certification_tier => '...' } or undef

Queries the configured plugin-store's public discovery API
(C<GET /api/plugins?koha_version_release=...>) for the plugin version whose C<kpz_url> exactly
matches the one given, returning its origin C<repo_url> and C<certification_tier> if found.
Returns C<undef> if C<plugin_store_url> isn't configured, the store isn't reachable, or no
release matches.

=cut

sub lookup_by_kpz_url {
    my ( $class, $kpz_url ) = @_;

    my $store_url = C4::Context->config('plugin_store_url');
    return unless $store_url;

    my $koha_version = C4::Context->preference('Version');
    my $ua           = Mojo::UserAgent->new;
    my $tx           = $ua->get("$store_url/api/plugins?koha_version_release=$koha_version");

    return unless $tx->res->code && $tx->res->code == 200;

    my $plugins = eval { $tx->res->json } // [];
    for my $plugin (@$plugins) {
        for my $release ( @{ $plugin->{releases} // [] } ) {
            next unless ( $release->{kpz_url} // '' ) eq $kpz_url;
            return {
                repo_url           => $plugin->{repo_url},
                certification_tier => $release->{certification_tier},
            };
        }
    }

    return;
}

1;

=head1 AUTHOR

Koha Development Team

=cut
```

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/Koha/Plugins/Store.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Koha/Plugins/Store.pm t/Koha/Plugins/Store.t
git commit -m "Bug 35837: (follow-up) Add Koha::Plugins::Store to resolve a kpz_url's plugin-store metadata

One HTTP call to the store's existing public discovery API, matching by
kpz_url, to recover the origin repo_url and certification_tier for a
version -- the missing piece Koha::Plugins::Install needs to check the
org-allowlist and PluginStoreMinimumLevel against a store-driven install."
```

---

## Task 4: Wire both entry points onto the shared routine

Supersedes Task 1's stopgap in `Koha::REST::V1::Plugins::add()`, and replaces
`plugins-upload.pl`'s existing ad-hoc substring-matched allowlist logic.

**Files:**
- Modify: `Koha/REST/V1/Plugins.pm`
- Modify: `plugins/plugins-upload.pl`
- Modify: `koha-tmpl/intranet-tmpl/prog/en/modules/plugins/plugins-home.tt` (the search-result install form)
- Modify: `t/db_dependent/api/v1/plugins.t` (Task 1's test, now asserting the real allowlist logic)

**Interfaces:**
- Consumes: `Koha::Plugins::Install->install(...)` and `Koha::Plugins::Store->lookup_by_kpz_url(...)` from Tasks 2–3.

- [ ] **Step 1: Write the failing test (extend Task 1's test)**

Replace the single subtest in `t/db_dependent/api/v1/plugins.t` with three, updating the test
count header to `tests => 2` → covering a mocked `Koha::Plugins::Store` so no real HTTP call
happens in this test:

```perl
use Test::More tests => 2;
use Test::NoWarnings;
use Test::Mojo;
use Test::MockModule;

use t::lib::TestBuilder;
use t::lib::Mocks;

use Koha::Database;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

my $t = Test::Mojo->new('Koha::REST::V1');
t::lib::Mocks::mock_preference( 'RESTBasicAuth', 1 );

subtest 'add()' => sub {

    plan tests => 6;

    $schema->storage->txn_begin;

    my $password = 'thePassword123';
    my $patron   = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { flags => 2**19 }    # plugins flag
        }
    );
    $patron->set_password( { password => $password, skip_validation => 1 } );
    my $userid = $patron->userid;

    t::lib::Mocks::mock_config( 'enable_plugins', 1 );
    t::lib::Mocks::mock_config( 'plugins_restricted', 0 );

    my $store_module    = Test::MockModule->new('Koha::Plugins::Store');
    my $install_module  = Test::MockModule->new('Koha::Plugins::Install');
    my $fetch_module     = Test::MockModule->new('File::Fetch');

    $fetch_module->mock( fetch => sub { return '/tmp/does-not-matter.kpz' } );

    $store_module->mock(
        lookup_by_kpz_url => sub {
            return { repo_url => 'https://github.com/openfifth/koha-plugin-coverflow', certification_tier => 'CERTIFIED' };
        }
    );

    $install_module->mock( install => sub { return ( 1, { digest => 'abc123' } ) } );

    $t->post_ok( "//$userid:$password\@/api/v1/plugins" => json => { kpz_url => 'https://example.com/plugin.kpz' } )
        ->status_is( 201, 'A successful install returns 201' );

    $install_module->mock( install => sub { return ( 0, { RESTRICTED => 1 } ) } );

    $t->post_ok( "//$userid:$password\@/api/v1/plugins" => json => { kpz_url => 'https://example.com/plugin.kpz' } )
        ->status_is( 403, 'A rejected install (per Koha::Plugins::Install) returns 403, not a silent install' );

    $t->post_ok( "//$userid:$password\@/api/v1/plugins" => json => {} )
        ->status_is( 400, 'Missing kpz_url is a 400, not a crash' );

    $schema->storage->txn_rollback;
};
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/db_dependent/api/v1/plugins.t`
Expected: FAIL — Task 1's implementation always sets `RESTRICTED` when `plugins_restricted` is
on and never calls `Koha::Plugins::Install`/`Koha::Plugins::Store` at all, so the mocks above are
never invoked and the first assertion (expecting `201`) fails.

- [ ] **Step 3: Write minimal implementation**

Replace the body of `sub add` in `Koha/REST/V1/Plugins.pm` with:

```perl
sub add {
    my $c = shift->openapi->valid_input or return;

    my $body    = $c->req->json;
    my $kpz_url = $body->{kpz_url};

    return $c->render( status => 400, openapi => { error => 'Missing kpz_url' } )
        unless $kpz_url;

    my $lookup = Koha::Plugins::Store->lookup_by_kpz_url($kpz_url);

    my $ff   = File::Fetch->new( uri => $kpz_url );
    my $file = eval { $ff->fetch };
    return $c->render( status => 500, openapi => { error => 'Could not download kpz_url' } )
        unless $file;

    my ($filename) = $kpz_url =~ m{([^/]+)$};

    my ( $ok, $result ) = Koha::Plugins::Install->install(
        {
            kpz_path           => $file,
            filename           => $filename,
            repo_url           => $lookup ? $lookup->{repo_url} : undef,
            certification_tier => $lookup ? $lookup->{certification_tier} : undef,
        }
    );

    return $c->render( status => 403, openapi => { error => 'Install rejected', details => $result } )
        unless $ok;

    return try {
        return $c->render(
            status  => 201,
            openapi => { success => 'Plugin installed' }
        );
    }
    catch {
        $c->unhandled_exception($_);
    };
}
```

Add to the top of `Koha/REST/V1/Plugins.pm`, alongside the existing `use` lines:

```perl
use File::Fetch;
use Koha::Plugins::Install;
use Koha::Plugins::Store;
```

Now update `plugins/plugins-home.tt`'s search-result install form (in the `[% IF search_results %]`
block) to also pass along the repo's origin URL, so `plugins-upload.pl` can check it:

```html
<form method="post" action="/cgi-bin/koha/plugins/plugins-upload.pl">
    [% INCLUDE 'csrf-token.inc' %]
    <input type="hidden" name="op" value="cud-Upload" />
    <input type="hidden" name="uploadfile" value="[% sr.result.install_name | html %]" />
    <input type="hidden" name="uploadlocation" value="[% sr.result.install_url | url %]" />
    <input type="hidden" name="repo_url" value="[% sr.result.html_url | url %]" />
    <button type="submit" value="Install" class="btn btn-default btn-sm btn-install-plugin"><i class="fa fa-download"></i> Install</button>
</form>
```

(`sr.result.html_url` is already populated for GitHub results; add the equivalent for the GitLab
branch of the search handler in `plugins-home.pl` — the GitLab result hash built there needs a
`html_url => $web_url` key added alongside its existing `name`/`tag_name`/etc. keys, since it
doesn't currently set one under that name.)

Now replace everything in `plugins/plugins-upload.pl` from `my $uploadfilename =
$input->param('uploadfile');` (the line immediately after the `enable_plugins`/`plugins_restricted`
early-exit checks) through to the end of the file — this includes, and replaces, the existing
declarations of `$uploadfilename`, `$uploadfile`, `$op`, `$tempfile`/`$tfh`, and `%errors`, not
just the `if` block that follows them:

```perl
my $uploadfilename = $input->param('uploadfile');
my $uploadfile      = $input->upload('uploadfile');
my $repo_url        = $input->param('repo_url');    # only present for search-result-driven installs
my $op              = $input->param('op') || q{};

my ( $tempfile, $tfh );
my %errors;

if ( ( $op eq 'cud-Upload' ) && ( $uploadfile || $uploadlocation ) ) {
    my $dirname = File::Temp::tempdir( CLEANUP => 1 );

    my $filesuffix;
    $filesuffix = $1 if $uploadfilename =~ m/(\..+)$/i;
    ( $tfh, $tempfile ) = File::Temp::tempfile( SUFFIX => $filesuffix, UNLINK => 1 );

    $errors{'NOWRITETEMP'} = 1 unless ( -w $dirname );

    if ($uploadlocation) {
        my $ua = Mojo::UserAgent->new( max_redirects => 5 );
        my $tx = $ua->get($uploadlocation);
        $tx->result->content->asset->move_to($tempfile);
    } elsif ($uploadfile) {
        while (<$uploadfile>) {
            print $tfh $_;
        }
        close $tfh;
    } else {
        $errors{'EMPTYUPLOAD'} = 1;
    }

    unless (%errors) {
        my ( $ok, $result ) = Koha::Plugins::Install->install(
            {
                kpz_path => $tempfile,
                filename => $uploadfilename,
                repo_url => $repo_url,
            }
        );
        %errors = %$result unless $ok;
    }

    $template->param( ERRORS => [ \%errors ] ) if %errors;
} elsif ( ( $op eq 'cud-Upload' ) && !$uploadfile && !$uploadlocation ) {
    warn "Problem uploading file or no file uploaded.";
}

if ( ( $uploadfile || $uploadlocation ) && !%errors && !$template->param('ERRORS') ) {
    print $input->redirect("/cgi-bin/koha/plugins/plugins-home.pl");
} else {
    output_html_with_http_headers $input, $cookie, $template->output;
}

exit;
```

Add to the top of `plugins/plugins-upload.pl`, alongside the existing `use` lines:

```perl
use Koha::Plugins::Install;
```

(`List::Util qw( any )` is no longer used in this file and can be removed from its `use`
statement; `Mojo::UserAgent` remains needed for the `uploadlocation` fetch branch.)

- [ ] **Step 4: Run test to verify it passes**

Run: `prove -l t/db_dependent/api/v1/plugins.t`
Expected: PASS. Also re-run `prove -l t/Koha/Plugins/Install.t t/Koha/Plugins/Store.t` to confirm
Tasks 2–3 are unaffected.

- [ ] **Step 5: Commit**

```bash
git add Koha/REST/V1/Plugins.pm plugins/plugins-upload.pl \
    koha-tmpl/intranet-tmpl/prog/en/modules/plugins/plugins-home.tt \
    plugins/plugins-home.pl t/db_dependent/api/v1/plugins.t
git commit -m "Bug 35837: (follow-up) Route both install entry points through Koha::Plugins::Install

Koha::REST::V1::Plugins::add() and plugins-upload.pl now share one
validate-then-install routine, checked against the plugin's actual origin
repo (via a plugin-store lookup for the REST path, via the search
result's own known repo for the legacy search-driven path) rather than a
substring match against a download URL. Supersedes the Task 1 stopgap."
```

---

## Task 5: `PluginStoreMinimumLevel` system preference

**Files:**
- Create: `installer/data/mysql/atomicupdate/bug_35837_plugin_store_minimum_level.pl`
- Create: `koha-tmpl/intranet-tmpl/prog/en/modules/admin/preferences/plugins.pref`
- Test: create `t/Koha/Plugins/Install.t` addition (already covers the syspref via
  `t::lib::Mocks::mock_preference` in Task 2 — no new test file needed; this task is config/data
  only, verified by re-running Task 2's existing "certification tier below
  PluginStoreMinimumLevel is rejected" subtest against the real syspref name once it exists in
  the DB).

**Interfaces:**
- Produces: system preference `PluginStoreMinimumLevel`, values `''` (off, default),
  `INCOMPLETE`, `STRUCTURAL`, `CERTIFIED` — already consumed by `Koha::Plugins::Install::_meets_minimum_level`
  from Task 2.

- [ ] **Step 1: Write the atomicupdate**

Create `installer/data/mysql/atomicupdate/bug_35837_plugin_store_minimum_level.pl`:

```perl
use Modern::Perl;
use Koha::Installer::Output qw(say_success);

return {
    bug_number  => "35837",
    description => "Add PluginStoreMinimumLevel system preference",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        $dbh->do(
            q{
                INSERT IGNORE INTO systempreferences (variable, value, options, explanation, type)
                VALUES ('PluginStoreMinimumLevel', '', 'INCOMPLETE|STRUCTURAL|CERTIFIED',
                    'Minimum plugin-store certification tier required to install a plugin known to originate from the plugin store. Leave empty to disable this check.',
                    'Choice')
            }
        );

        say $out "Added new system preference 'PluginStoreMinimumLevel'";
    },
};
```

- [ ] **Step 2: Run the atomicupdate**

Run: `misc/devel/update_dbix_class_files.pl` is not needed here (no schema change, only a
`systempreferences` row) — run the update itself:
`updatedatabase.pl` (via `koha-shell kohadev -c update_dbix_class_files.pl` or the project's own
`kd`/KTD wrapper for applying atomicupdates). Verify with:
`SELECT * FROM systempreferences WHERE variable = 'PluginStoreMinimumLevel';` — expect one row
with `value = ''`.

- [ ] **Step 3: Add the preferences page entry**

Create `koha-tmpl/intranet-tmpl/prog/en/modules/admin/preferences/plugins.pref`:

```yaml
Plugins:
    Installation:
        -
            - "Require plugins to be at least "
            - pref: PluginStoreMinimumLevel
              default: ""
              choices:
                  "": "no minimum level (off)"
                  INCOMPLETE: "Incomplete"
                  STRUCTURAL: "Structural"
                  CERTIFIED: "Certified"
            - " on the plugin store to be installable. Only applies to plugins with a known plugin-store origin; plugins with no known origin (manual uploads, or search results from a configured plugin_repos entry) are unaffected by this setting."
```

- [ ] **Step 4: Verify the preference appears in the staff interface**

Visit `/cgi-bin/koha/admin/preferences.pl?tab=plugins` (or search for `PluginStoreMinimumLevel`
in the general preference search) and confirm the dropdown renders with the four choices above.

- [ ] **Step 5: Re-run Task 2's minimum-level test against the real syspref**

Run: `prove -l t/Koha/Plugins/Install.t`
Expected: still PASS — Task 2's test already mocks the preference by name via
`t::lib::Mocks::mock_preference('PluginStoreMinimumLevel', ...)`, which works whether or not the
syspref row exists yet, but confirms the name matches exactly what this task just created.

- [ ] **Step 6: Commit**

```bash
git add installer/data/mysql/atomicupdate/bug_35837_plugin_store_minimum_level.pl \
    koha-tmpl/intranet-tmpl/prog/en/modules/admin/preferences/plugins.pref
git commit -m "Bug 35837: (follow-up) Add PluginStoreMinimumLevel system preference

Gates plugin-store-driven installs on the store's own certification tier
for that version, independent of and in addition to the org-allowlist
check in Koha::Plugins::Install -- both must pass, neither alone is
sufficient, per the migration design."
```

---

## Task 6: Retire the live GitHub/GitLab search; use the plugin-store discovery API

**Files:**
- Modify: `plugins/plugins-home.pl`

**Interfaces:**
- Consumes: the plugin-store's public discovery API directly (`GET
  /api/plugins?koha_version_release=...`), same endpoint `Koha::Plugins::Store` already calls —
  this task doesn't reuse `Koha::Plugins::Store` itself (that module answers a different question,
  "what does the store know about *this exact kpz_url*", not "list everything compatible with my
  Koha version"), but does reuse the same config key (`plugin_store_url`) and the same
  `Mojo::UserAgent` approach.

- [ ] **Step 1: Write the failing test**

There is no existing test file for `plugins/plugins-home.pl` (confirmed — it's a CGI script with
no `t/db_dependent` coverage today). Rather than introduce full CGI-script test infrastructure
for this one change, extract the search logic into a small, directly-testable function first.

Create `Koha/Plugins/Search.pm`:

```perl
package Koha::Plugins::Search;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use Mojo::UserAgent;

use C4::Context;

=head1 NAME

Koha::Plugins::Search

=head1 API

=head2 Class methods

=head3 search

    my ( $results, $errors ) = Koha::Plugins::Search->search($term);

Searches the configured plugin-store for plugins compatible with this Koha's own version, whose
name or description contains C<$term> (case-insensitive). Returns C<( \@results, \@errors )> in
the same shape C<plugins/plugins-home.pl>'s template already expects from the legacy
GitHub/GitLab search (a list of C<{ repo => {...}, result => {...} }> hashes).

=cut

sub search {
    my ( $class, $term ) = @_;

    my ( @results, @errors );

    my $store_url = C4::Context->config('plugin_store_url');
    unless ($store_url) {
        push @errors, { repo => { name => 'plugin store' }, error => 'No plugin store configured' };
        return ( \@results, \@errors );
    }

    my $koha_version = C4::Context->preference('Version');
    my $ua           = Mojo::UserAgent->new;
    my $tx           = $ua->get("$store_url/api/plugins?koha_version_release=$koha_version");

    unless ( $tx->res->code && $tx->res->code == 200 ) {
        push @errors, { repo => { name => 'plugin store' }, error => 'Could not reach the plugin store' };
        return ( \@results, \@errors );
    }

    my $plugins = eval { $tx->res->json } // [];
    for my $plugin (@$plugins) {
        next
            unless lc( $plugin->{name}        // '' ) =~ /\Q$term\E/i
            or     lc( $plugin->{description} // '' ) =~ /\Q$term\E/i;

        for my $release ( @{ $plugin->{releases} // [] } ) {
            my ($install_name) = ( $release->{kpz_url} // '' ) =~ m{([^/]+)$};
            push @results,
                {
                repo => { name => $plugin->{repo_url} },
                result => {
                    name         => $plugin->{name},
                    description  => $plugin->{description},
                    html_url     => $plugin->{repo_url},
                    tag_name     => $release->{tag_name} // $release->{version},
                    install_name => $install_name // '',
                    install_url  => $release->{kpz_url},
                },
                };
        }
    }

    return ( \@results, \@errors );
}

1;

=head1 AUTHOR

Koha Development Team

=cut
```

Create `t/Koha/Plugins/Search.t`:

```perl
#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use Test::More tests => 3;
use Test::NoWarnings;
use Test::MockModule;

use t::lib::Mocks;

use Koha::Plugins::Search;

subtest 'returns an error when no plugin store is configured' => sub {
    plan tests => 2;
    t::lib::Mocks::mock_config( 'plugin_store_url', undef );
    my ( $results, $errors ) = Koha::Plugins::Search->search('coverflow');
    is( scalar @$results, 0, 'no results' );
    is( scalar @$errors,  1, 'one error reported' );
};

subtest 'filters by name/description, case-insensitively' => sub {
    plan tests => 3;

    t::lib::Mocks::mock_config( 'plugin_store_url', 'http://store.example.com' );
    t::lib::Mocks::mock_preference( 'Version', '26.06.00.000' );

    my $ua_module = Test::MockModule->new('Mojo::UserAgent');
    $ua_module->mock(
        get => sub {
            my $tx   = Mojo::Transaction::HTTP->new;
            my $body = '['
                . '{"name":"CoverFlow plugin","description":"widget","repo_url":"https://github.com/a/b","releases":[{"kpz_url":"https://example.com/a.kpz","tag_name":"v1"}]},'
                . '{"name":"Other plugin","description":"unrelated","repo_url":"https://github.com/c/d","releases":[{"kpz_url":"https://example.com/b.kpz","tag_name":"v1"}]}'
                . ']';
            $tx->res->code(200);
            $tx->res->body($body);
            return $tx;
        }
    );

    my ( $results, $errors ) = Koha::Plugins::Search->search('coverflow');
    is( scalar @$errors,  0, 'no errors' );
    is( scalar @$results, 1, 'exactly one matching plugin' );
    is( $results->[0]->{result}->{name}, 'CoverFlow plugin', 'the matching plugin is returned' );
};

subtest 'reports an error when the store is unreachable' => sub {
    plan tests => 1;

    t::lib::Mocks::mock_config( 'plugin_store_url', 'http://store.example.com' );
    t::lib::Mocks::mock_preference( 'Version', '26.06.00.000' );

    my $ua_module = Test::MockModule->new('Mojo::UserAgent');
    $ua_module->mock(
        get => sub {
            my $tx = Mojo::Transaction::HTTP->new;
            $tx->res->code(500);
            return $tx;
        }
    );

    my ( $results, $errors ) = Koha::Plugins::Search->search('anything');
    is( scalar @$errors, 1, 'one error reported when the store returns a non-200' );
};
```

- [ ] **Step 2: Run test to verify it fails**

Run: `prove -l t/Koha/Plugins/Search.t`
Expected: FAIL with "Can't locate Koha/Plugins/Search.pm in @INC"

- [ ] **Step 3: Confirm `Koha::Plugins::Search` (already written above) makes the test pass**

Run: `prove -l t/Koha/Plugins/Search.t`
Expected: PASS

- [ ] **Step 4: Wire `plugins/plugins-home.pl` onto it, removing the live GitHub/GitLab search**

Replace the whole `if ($plugin_search) { ... }` block (previously covering the GitHub and GitLab
API-calling code) with:

```perl
if ($plugin_search) {
    my ( $results, $errors ) = Koha::Plugins::Search->search($plugin_search);

    $template->param(
        search_results => $results,
        search_errors  => $errors,
        search_term    => $plugin_search,
    );
}
```

Change:

```perl
$template->param( can_search => C4::Context->config('plugin_repos') ? 1 : 0 );
```

to:

```perl
$template->param( can_search => C4::Context->config('plugin_store_url') ? 1 : 0 );
```

Remove the now-unused `use JSON qw( from_json );` and `use LWP::Simple qw( get );` lines, and add:

```perl
use Koha::Plugins::Search;
```

- [ ] **Step 5: Manually verify in the staff interface**

With `plugin_store_url` configured (e.g. pointing at the local Docker koha-plugin-store instance
already running for this project — see `koha-conf.xml`'s `plugin_store_url` entry added earlier
this session), visit `/cgi-bin/koha/plugins/plugins-home.pl`, enter a search term matching one of
the seeded demo plugins (e.g. "coverflow"), and confirm the results table renders using data from
the plugin-store rather than a live GitHub/GitLab call — check the Docker container logs for the
plugin-store app (`docker compose logs app`) to confirm the `GET /api/plugins` request actually
landed there.

- [ ] **Step 6: Commit**

```bash
git add Koha/Plugins/Search.pm t/Koha/Plugins/Search.t plugins/plugins-home.pl
git commit -m "Bug 35837: (follow-up) Replace live GitHub/GitLab plugin search with the plugin store

plugins-home.pl's search feature no longer calls GitHub's/GitLab's APIs
directly at request time -- it queries the plugin-store's existing public
discovery API instead, the same one the plugin-store's own Vue client
uses. Retires ~80 lines of hand-rolled release-parsing per service.
can_search now reflects whether plugin_store_url is configured, not
plugin_repos (which remains meaningful only for the org-allowlist
install-time check in Koha::Plugins::Install, not for discovery)."
```

---

## Explicitly not covered by this plan (tracked separately, per the design doc)

- Store-side Ed25519 signing and the corresponding signature-verification step in
  `Koha::Plugins::Install::install` (currently a documented no-op).
- GitLab support in the plugin-store's own discovery API (the retired legacy search supported it;
  the store currently doesn't ingest GitLab repos at all — `Koha::Plugins::Search` will simply
  never surface GitLab-hosted plugins until the store gains that capability).
- Any reshaping of `plugin_repos`'s config shape (left as-is per the design doc's "still open" note).
