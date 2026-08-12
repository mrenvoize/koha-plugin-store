# Plugin Details/Edit Page Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `/plugins/:slug` (public show page) and `/plugins/edit/:id` (owner-only edit
page) into one tabbed page at `/plugins/:slug`, with a display-first Details tab (edit via
modal) and a Releases tab that shows full certification/check detail — published-only for
the public, all statuses for the owner — replacing the currently-broken plugin-details edit
flow.

**Architecture:** All changes live in the `KohaPluginStore` Mojolicious app
(`worktrees/check-pipeline`). `Controller::Plugins::show` grows to compute ownership and
conditionally fetch live GitHub release data; a new `update_plugin` action handles the modal's
form submission; `edit_form`, its route, and `templates/plugins/edit.html.ep` are deleted;
`templates/plugins/show.html.ep` is restructured into two Bootstrap tabs.

**Tech Stack:** Mojolicious (Perl), Mojolicious::Lite `.html.ep` templates, Bootstrap 5
(tabs + modal, `data-bs-toggle`), Postgres via `Mojo::Pg`, Test::Mojo + Test::More.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-12-plugin-page-merge-design.md` (this plan's source of truth).
- Ownership check uses numeric `==` against `$c->session->{developer}->{id}` vs
  `$plugin->developer_id`, matching the existing `edit_form` convention
  (`lib/KohaPluginStore/Controller/Plugins.pm:67` on the pre-change file).
- No new validation beyond "all four fields (`name`, `description`, `repo_url`, `author`)
  must be non-blank" — matches the existing form's own HTML `required` attributes. Do not
  add format/length/URL validation.
- Public visitors must never trigger a live GitHub API call. `github_releases` is fetched
  only when the viewer is the confirmed owner.
- The base commit for this work is `c20d526` ("Surface per-check review results on the
  plugin show page") on branch `worktree-check-pipeline` in
  `/home/martin/Projects/koha/tooling/koha-plugin-store/worktrees/check-pipeline` — the
  per-check-detail bugfix this design builds on is already committed there.
- Test DB reset truncates `plugin_versions, plugins, developers, plugin_contributors,
  minion_jobs, minion_locks, minion_schedules, minion_workers` (see `t/lib/TestDB.pm`);
  `review_checks` cascades via FK, so no separate truncation is needed for it.
- Run tests via: `docker compose exec -T app bash -lc 'export
  PERL5LIB=$(pwd)/local/lib/perl5; export
  KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store";
  prove -l t/<file>.t'` — the compose stack (`check-pipeline-app-1`,
  `check-pipeline-postgres-1`, `check-pipeline-worker-1`) is already running. After editing
  a file, copy it into the container first: `docker compose cp <path> app:/app/<path>`
  (the running containers do not have a live bind-mount of the worktree).

---

### Task 1: Controller — ownership-aware `show`, and a private shared data-loading helper

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (the `show` sub, currently lines 91-122
  on top of commit `c20d526`)
- Test: `t/plugins_show.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Model::Plugin`, `Model::PluginVersion`, `Model::PluginContributor`,
  `Model::ReviewCheck` (all already `use`d in the file), `KohaPluginStore::GitHub::fetch_releases`
  (already `use KohaPluginStore::GitHub;` at the top of the file).
- Produces: a private sub `_plugin_page_stash($c, $plugin)` returning a hashref with keys
  `plugin, versions, contributors, still_processing, checks_by_version, is_owner,
  github_releases` — used by both `show` and (in Task 3) `update_plugin`'s validation-failure
  path. `is_owner` is `1` or `0` (never undef, so templates can test it directly).
  `github_releases` is `undef` when `is_owner` is false.

This task changes what data `show` gathers (ownership + conditional GitHub fetch) without yet
changing the template — the template still only uses `plugin/versions/contributors/
still_processing/checks_by_version` at the end of this task, so `is_owner`/`github_releases`
are stashed but unused until Task 2. This keeps the task independently testable: it proves the
right data is computed before the template is touched.

- [ ] **Step 1: Write the failing test for ownership detection and conditional GitHub fetch**

Add to `t/plugins_show.t`, after the existing `use` lines add
`use KohaPluginStore::Model::Developer;` and before `done_testing();`:

```perl
subtest 'a logged-in owner triggers a GitHub releases fetch; a public visitor does not' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # logs in as mockdev
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    my $fetch_calls = 0;
    {
        no strict 'refs';
        no warnings 'redefine';
        *KohaPluginStore::GitHub::fetch_releases = sub { $fetch_calls++; return []; };
    }

    $t->get_ok( '/plugins/' . $plugin->slug )->status_is(200);
    is( $fetch_calls, 1, 'owner view fetches GitHub releases' );

    $t->get_ok('/logout');
    $fetch_calls = 0;
    $t->get_ok( '/plugins/' . $plugin->slug )->status_is(200);
    is( $fetch_calls, 0, 'public view does not fetch GitHub releases' );
};
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
docker compose cp t/plugins_show.t app:/app/t/plugins_show.t
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/plugins_show.t'
```

Expected: FAIL — `fetch_calls` is `0` for the owner case too, since `show` never calls
`fetch_releases` today.

- [ ] **Step 3: Implement `_plugin_page_stash` and update `show`**

Replace the current `sub show` in `lib/KohaPluginStore/Controller/Plugins.pm` (the version from
commit `c20d526`) with:

```perl
sub _plugin_page_stash {
    my ( $c, $plugin ) = @_;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->search(
        { plugin_id => $plugin->id }, { order_by => { -desc => 'id' } }
    );
    my @contributors = KohaPluginStore::Model::PluginContributor->new( pg => $c->pg )->search(
        { plugin_id => $plugin->id }, { order_by => { -desc => 'contributions_count' } }
    );

    my $still_processing = grep { $_->status eq 'submitted' || $_->status eq 'checks_running' } @versions;

    my %checks_by_version;
    if (@versions) {
        my @checks = KohaPluginStore::Model::ReviewCheck->new( pg => $c->pg )->search(
            { plugin_version_id => [ map { $_->id } @versions ] }, { order_by => 'check_name' }
        );
        push @{ $checks_by_version{ $_->plugin_version_id } }, $_ for @checks;
    }

    my $is_owner = $c->session->{developer} && $c->session->{developer}->{id} == $plugin->developer_id ? 1 : 0;

    my $github_releases;
    if ($is_owner) {
        my $config = $c->app->plugin('Config');
        $github_releases = KohaPluginStore::GitHub::fetch_releases( $config->{github_app_token}, $plugin->repo_url );

        my $existing_tags = { map { $_->tag_name => 1 } @versions };
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
    }

    return {
        plugin            => $plugin,
        versions          => \@versions,
        contributors      => \@contributors,
        still_processing  => $still_processing,
        checks_by_version => \%checks_by_version,
        is_owner          => $is_owner,
        github_releases   => $github_releases,
    };
}

sub show ($c) {
    my $slug = $c->param('slug');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { slug => $slug } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;

    $c->stash( %{ $c->_plugin_page_stash($plugin) } );
    $c->render('plugins/show');
}
```

Note `_plugin_page_stash` is called as `$c->_plugin_page_stash($plugin)` (a controller method,
not a plain sub) so it can use `$c->session`/`$c->app` — define it as a regular named sub in the
same package; Mojolicious controllers dispatch any sub in the package as a method when called via
`$c->`.

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: PASS — both `is(...)` assertions succeed, and all
pre-existing subtests in the file still pass (`prove -l t/plugins_show.t` reports `All tests
successful`).

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm t/plugins_show.t
git commit -m "Add ownership-aware data loading for the plugin show page"
```

---

### Task 2: Template — tabbed Details/Releases layout with visibility filtering

**Files:**
- Modify: `templates/plugins/show.html.ep` (the version from commit `c20d526`)
- Test: `t/plugins_show.t`

**Interfaces:**
- Consumes: the stash produced by Task 1's `_plugin_page_stash` — `plugin, versions,
  contributors, still_processing, checks_by_version, is_owner, github_releases`.
- Produces: two Bootstrap tabs, `#plugin-details-tab` and `#plugin-releases-tab`, each
  containing an element with `id="main-details"` / `id="main-releases"` respectively (used by
  Task 2's own tests and reused by Task 3's error-path tests to assert tab content without
  relying on `text_like`'s parent-only-text limitation — see the note in Task 1's test about
  why `content_like`, not `text_like`, is used for deep-nested assertions in this file).

This task does NOT add the edit modal itself (Task 3 owns the update action and its modal) —
it only restructures the page into tabs and applies the public/owner Releases-tab filtering.
The Details tab this task produces is read-only (name/description/repo_url/author/
contributors) with a placeholder "Edit" button that does nothing yet (`type="button"` with no
handler) — Task 3 wires it to open the modal.

- [ ] **Step 1: Write the failing tests for tab structure and visibility filtering**

Add to `t/plugins_show.t` before `done_testing();`:

```perl
subtest 'public visitor sees only published versions and no GitHub-available section' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v0.9.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/v1\.0\.0/)
      ->content_unlike(qr/v0\.9\.0/)
      ->content_unlike(qr/Releases from.*github/is)
      ->element_exists_not('#edit-plugin-modal');
};

subtest 'owner sees all versions plus the GitHub-available section and an edit control' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v0.9.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    {
        no strict 'refs';
        no warnings 'redefine';
        *KohaPluginStore::GitHub::fetch_releases = sub {
            return [ { name => 'v2.0.0', tag_name => 'v2.0.0', published_at => '2026-01-01', assets => [ { name => 'plugin.kpz' } ] } ];
        };
    }

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/v1\.0\.0/)
      ->content_like(qr/v0\.9\.0/)
      ->content_like(qr/v2\.0\.0/)
      ->element_exists('#edit-plugin-modal');

    $t->get_ok('/logout');
};
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
docker compose cp t/plugins_show.t app:/app/t/plugins_show.t
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/plugins_show.t'
```

Expected: FAIL — the current template shows all versions to everyone and has no
`#edit-plugin-modal` element.

- [ ] **Step 3: Rewrite the template**

Replace the entire contents of `templates/plugins/show.html.ep` with:

```
% my $plugin = stash 'plugin';
% my $versions = stash 'versions';
% my $contributors = stash 'contributors';
% my $still_processing = stash 'still_processing';
% my $checks_by_version = stash('checks_by_version') || {};
% my $is_owner = stash 'is_owner';
% my $github_releases = stash('github_releases') || [];
% my %tier_badge = ( CERTIFIED => 'text-bg-success', STRUCTURAL => 'text-bg-warning', INCOMPLETE => 'text-bg-danger' );
% my $plugin_title = $plugin->name || 'Processing submission...';
% title $plugin_title;
% layout 'default';
% if ($still_processing) {
  %= content_for 'head' => begin
<meta http-equiv="refresh" content="5">
  %= end
% }

% content_for 'sidebar' => begin
  %= include 'partial/side_menu'
% end

<ul class="nav nav-tabs" id="plugin-tabs" role="tablist">
  <li class="nav-item" role="presentation">
    <button class="nav-link active" id="plugin-details" data-bs-toggle="tab" data-bs-target="#plugin-details-tab" type="button" role="tab" aria-controls="plugin-details-tab" aria-selected="true">Details</button>
  </li>
  <li class="nav-item" role="presentation">
    <button class="nav-link" id="plugin-releases" data-bs-toggle="tab" data-bs-target="#plugin-releases-tab" type="button" role="tab" aria-controls="plugin-releases-tab" aria-selected="false">Releases</button>
  </li>
</ul>
<div class="tab-content" id="plugin-tab-content">
  <div class="tab-pane fade show active" id="plugin-details-tab" role="tabpanel" aria-labelledby="plugin-details">
    <div id="main-details">
      <h2><%= $plugin_title %>
        % if ($is_owner) {
        <button type="button" class="btn btn-sm btn-outline-secondary" data-bs-toggle="modal" data-bs-target="#edit-plugin-modal">Edit</button>
        % }
      </h2>
      % if ($plugin->description) {
      <p><%= $plugin->description %></p>
      % }
      <dl class="row">
        <dt class="col-sm-2">Repository</dt>
        <dd class="col-sm-10"><%= $plugin->repo_url %></dd>
        <dt class="col-sm-2">Author</dt>
        <dd class="col-sm-10"><%= $plugin->author %></dd>
      </dl>

      % if (@$contributors) {
      <h3>Contributors</h3>
      <ul class="list-unstyled">
        % for my $contributor (@$contributors) {
        <li><img src="<%= $contributor->avatar_url %>" width="24" height="24"> <%= $contributor->github_username %></li>
        % }
      </ul>
      % }
    </div>
  </div>
  <div class="tab-pane fade" id="plugin-releases-tab" role="tabpanel" aria-labelledby="plugin-releases">
    <div id="main-releases">
      <table class="table">
        <thead>
          <tr>
            <th>Tag</th>
            <th>Version</th>
            <th>Status</th>
            <th>Certification</th>
            <th>Checks</th>
          </tr>
        </thead>
        <tbody>
          % for my $version (@$versions) {
          % next if !$is_owner && $version->status ne 'published';
          <tr>
            %= t td => $version->tag_name
            %= t td => ($version->version || '-')
            %= t td => $version->status
            <td>
              % if ($version->certification_tier) {
                <span class="badge <%= $tier_badge{$version->certification_tier} || 'text-bg-secondary' %>"><%= $version->certification_tier %></span>
              % }
            </td>
            <td>
              % if ($version->error_message) {
                <div class="alert alert-warning py-2 mb-2"><%= $version->error_message %></div>
              % }
              % my $checks = $checks_by_version->{$version->id} || [];
              % if (@$checks) {
              <table class="table table-sm mb-0">
                <thead>
                  <tr>
                    <th>Check</th>
                    <th>Required</th>
                    <th>Result</th>
                    <th>Message</th>
                  </tr>
                </thead>
                <tbody>
                  % for my $check (@$checks) {
                  <tr class="<%= $check->passed ? 'text-success' : 'text-danger' %>">
                    %= t td => $check->check_name
                    %= t td => ($check->required ? 'Required' : 'Advisory')
                    %= t td => ($check->passed ? 'Passed' : 'Failed')
                    %= t td => ($check->message || '')
                  </tr>
                  % }
                </tbody>
              </table>
              % }
            </td>
          </tr>
          % }
        </tbody>
      </table>

      % if ($is_owner) {
      <h3>Releases from <i class='bx bxl-github'></i> github:</h3>
      <table class="table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Tag name</th>
            <th>Published at</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          % for my $release (@$github_releases) {
            % if ($release->{message}->{success}) {
            <tr class="text-success">
            % } elsif ($release->{message}->{error}) {
            <tr class="text-danger">
            % } else {
            <tr>
            % }
              %= t td => $release->{name}
              %= t td => $release->{tag_name}
              %= t td => $release->{published_at}
              % if ($release->{message}->{success}) {
              %= t td => $release->{message}->{success}
              % } elsif ($release->{message}->{error}) {
              %= t td => $release->{message}->{error}
              % } else {
              %= t td => form_for '/new-release' => (method => 'POST') => begin
                <input type="hidden" name="plugin_id" value="<%= $plugin->id %>">
                <input type="hidden" name="tag_name" value="<%= $release->{tag_name} %>">
                <button type="submit" class="btn btn-primary">Add this release</button>
              % end
              % }
            </tr>
          % }
        </tbody>
      </table>
      % }
    </div>
  </div>
</div>

% if ($is_owner) {
<div class="modal fade" id="edit-plugin-modal" tabindex="-1" aria-labelledby="edit-plugin-modal-label" aria-hidden="true">
  <div class="modal-dialog">
    <div class="modal-content">
      %= form_for '/plugins/'.$plugin->slug.'/edit' => (method => 'POST') => begin
        <div class="modal-header">
          <h5 class="modal-title" id="edit-plugin-modal-label">Edit plugin</h5>
          <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>
        </div>
        <div class="modal-body">
          <div class="mb-3">
            <label for="name">Name:</label>
            <input required type="text" class="form-control" name="name" id="name" value="<%= $plugin->name %>">
          </div>
          <div class="mb-3">
            <label for="description">Description:</label>
            <input required type="text" class="form-control" name="description" id="description" value="<%= $plugin->description %>">
          </div>
          <div class="mb-3">
            <label for="repo_url">Repository URL:</label>
            <input required type="text" class="form-control" name="repo_url" id="repo_url" value="<%= $plugin->repo_url %>">
          </div>
          <div class="mb-3">
            <label for="author">Author:</label>
            <input required type="text" class="form-control" name="author" id="author" value="<%= $plugin->author %>">
          </div>
        </div>
        <div class="modal-footer">
          <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button>
          <button type="submit" class="btn btn-primary">Save changes</button>
        </div>
      % end
    </div>
  </div>
</div>
% }
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: PASS for all subtests in `t/plugins_show.t`, including
the two new ones and the pre-existing ones from Task 1 and the earlier bugfix commit.

- [ ] **Step 5: Commit**

```bash
git add templates/plugins/show.html.ep t/plugins_show.t
git commit -m "Restructure plugin show page into Details/Releases tabs with owner-only visibility"
```

---

### Task 3: `update_plugin` action, route, and removal of the old edit page

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (add `update_plugin`, delete `edit_form`)
- Modify: `lib/KohaPluginStore.pm` (route table)
- Modify: `templates/partial/table/plugins.html.ep` (drop the separate Edit link)
- Delete: `templates/plugins/edit.html.ep`
- Test: create `t/plugins_update.t`

**Interfaces:**
- Consumes: `_plugin_page_stash` from Task 1 (reused for the validation-failure re-render).
- Produces: `POST /plugins/:slug/edit` → `update_plugin`, which either redirects to
  `/plugins/:slug` (success) or re-renders `plugins/show` with `errors` stashed (failure —
  the template needs one small addition, Step 3b below, to show that banner and pre-fill the
  modal from `$c->param(...)` when `errors` is present).

- [ ] **Step 1: Write the failing tests for `update_plugin`**

Create `t/plugins_update.t`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::Developer;

reset_db();

my $t = test_app();

subtest 'unknown slug is a 404' => sub {
    $t->post_ok( '/plugins/does-not-exist/edit' => form => { name => 'x', description => 'x', repo_url => 'x', author => 'x' } )
      ->status_is(404);
};

subtest 'a non-owner cannot update the plugin' => sub {
    reset_db();

    # The real owner -- a different developer than the one who logs in below.
    my $real_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'real-owner', username => 'realowner' }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # logs in as mockdev, NOT $real_owner
    $t->app->config->{oauth_mock} = 0;

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $real_owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' => form => { name => 'Changed', description => 'x', repo_url => 'x', author => 'x' } )
      ->status_is(401);

    $t->get_ok('/logout');
};

subtest 'a blank required field re-renders the page with an error and preserves input' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget', author => 'Dev', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' => form => { name => 'Widget', description => '', repo_url => 'https://github.com/dev/widget', author => 'Dev' } )
      ->status_is(200)
      ->content_like(qr/required/i)
      ->element_exists('input[name="name"][value="Widget"]');

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->description, 'Original', 'description was not changed on validation failure' );

    $t->get_ok('/logout');
};

subtest 'a valid update persists and redirects to the plugin page' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget', author => 'Dev', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' =>
        form => { name => 'Widget', description => 'Updated description', repo_url => 'https://github.com/dev/widget', author => 'Dev' } )
      ->status_is(302)
      ->header_is( Location => '/plugins/' . $plugin->slug );

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->description, 'Updated description', 'description was updated' );

    $t->get_ok('/logout');
};

done_testing();
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
docker compose cp t/plugins_update.t app:/app/t/plugins_update.t
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/plugins_update.t'
```

Expected: FAIL — the route doesn't exist yet, so every request 404s (including the ones
expecting 401/200/302), and the "unknown slug" subtest's 404 accidentally passes for the wrong
reason. This is expected at this stage; Step 4 confirms the right behavior for the right reason.

- [ ] **Step 3a: Add `update_plugin`, remove `edit_form`, in `Controller::Plugins.pm`**

Delete the entire `sub edit_form { ... }` block (lines 56-89 on top of commit `c20d526`).

Add this new sub (placed after `_plugin_page_stash`/`show`, matching the file's existing
top-to-bottom ordering by route):

```perl
sub update_plugin ($c) {
    my $slug = $c->param('slug');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { slug => $slug } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;
    return $c->render( text => 'Unauthorized', status => 401 )
        unless $c->session->{developer} && $c->session->{developer}->{id} == $plugin->developer_id;

    my %fields = map { $_ => $c->param($_) } qw(name description repo_url author);

    for my $field (qw(name description repo_url author)) {
        next if defined $fields{$field} && length $fields{$field};

        $c->stash( %{ $c->_plugin_page_stash($plugin) } );
        $c->stash( errors => ['All fields are required.'], form_values => \%fields );
        return $c->render('plugins/show');
    }

    $plugin->update( \%fields );

    return $c->redirect_to( '/plugins/' . $plugin->slug );
}
```

- [ ] **Step 3b: Add the error-banner and pre-fill support to the template**

In `templates/plugins/show.html.ep` (from Task 2), add near the top, after the existing stash
reads:

```
% my $errors = stash('errors') || [];
% my $form_values = stash('form_values') || {};
```

Add an error banner right after the `<ul class="nav nav-tabs" ...>` block's closing `</ul>`,
before `<div class="tab-content" ...>`:

```
% if (@$errors) {
<div class="alert alert-danger">
  <ul class="mb-0">
    % for my $error (@$errors) {
    <li><%= $error %></li>
    % }
  </ul>
</div>
% }
```

Change each modal input's `value` attribute to prefer the failed submission's value over the
plugin's current value, e.g. for `name`:

```
<input required type="text" class="form-control" name="name" id="name" value="<%= $form_values->{name} // $plugin->name %>">
```

Apply the same `$form_values->{FIELD} // $plugin->FIELD` pattern to `description`, `repo_url`,
and `author`'s `value` attributes.

Finally, when `@$errors`, the modal must already be open and the Details tab active on page
load (it is active by default already) — add this at the very end of the template, after the
closing `% } # is_owner` of the modal block:

```
% if (@$errors) {
<script>
document.addEventListener('DOMContentLoaded', function () {
  new bootstrap.Modal(document.getElementById('edit-plugin-modal')).show();
});
</script>
% }
```

- [ ] **Step 3c: Update the route table**

In `lib/KohaPluginStore.pm`, replace:

```perl
    $r->get('/plugins/edit/:id')->requires( user_authenticated => 1 )->to('plugins#edit_form');
    $r->get('/plugins/:slug')->to('plugins#show');
```

with:

```perl
    $r->get('/plugins/:slug')->to('plugins#show');
    $r->post('/plugins/:slug/edit')->to('plugins#update_plugin');
```

`update_plugin` does its own 401 check (matching `new_plugin`'s pattern of not gating simple
ownership checks behind the `user_authenticated` route condition), so this route is not marked
`requires( user_authenticated => 1 )`.

- [ ] **Step 3d: Update `templates/partial/table/plugins.html.ep`**

Remove the now-dead Edit link column entry:

```
      % if (logged_in_user && logged_in_user->id eq $plugin->developer_id){
      %= t td => link_to 'Edit' => 'plugins/edit/'.$plugin->id
      % }
```

Delete this block entirely (both the `%` conditional lines and the `%=` line between them). The
`<th>Actions</th>` header stays — leaving an empty cell for non-owners' rows is consistent with
how the table already renders (columns don't reflow per-row), and reworking the header is out
of scope for this plan.

- [ ] **Step 3e: Delete the old edit template**

```bash
git rm templates/plugins/edit.html.ep
```

- [ ] **Step 4: Sync files into the container and run the tests to verify they pass**

```bash
docker compose cp lib/KohaPluginStore/Controller/Plugins.pm app:/app/lib/KohaPluginStore/Controller/Plugins.pm
docker compose cp lib/KohaPluginStore.pm app:/app/lib/KohaPluginStore.pm
docker compose cp templates/plugins/show.html.ep app:/app/templates/plugins/show.html.ep
docker compose cp templates/partial/table/plugins.html.ep app:/app/templates/partial/table/plugins.html.ep
docker compose exec -T app rm -f /app/templates/plugins/edit.html.ep
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/plugins_update.t t/plugins_show.t t/plugins_listing.t'
```

Expected: PASS on all three files (`t/plugins_listing.t` is included as a regression check —
it does not assert on the old Edit link, confirmed by inspection during planning, so it needs
no changes here).

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm lib/KohaPluginStore.pm \
  templates/plugins/show.html.ep templates/partial/table/plugins.html.ep \
  t/plugins_update.t
git rm templates/plugins/edit.html.ep
git commit -m "Replace the broken plugin edit page with a modal-based update action"
```

---

### Task 4: Full-suite verification and cleanup

**Files:** none (verification only)

**Interfaces:** none — this task confirms Tasks 1-3 integrate cleanly and leaves no stray
references to the removed page.

- [ ] **Step 1: Run the full test suite**

```bash
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/'
```

Expected: every file passes except `t/task_process_plugin_version.t` and `t/login.t`, which
are pre-existing, unrelated failures (confirmed independent of this plan's changes — see
Global Constraints; `t/login.t` is already documented in `CLAUDE.md` as stale). Do not
"fix" either as part of this plan; if any *other* file fails, that is a real regression from
Tasks 1-3 and must be root-caused before continuing.

- [ ] **Step 2: Grep for stray references to the removed route/template**

```bash
grep -rn "plugins/edit\|edit_form\|plugins::edit" lib/ templates/ t/ --include='*.pm' --include='*.ep' --include='*.t'
```

Expected: no output. If anything remains (e.g. a stale link elsewhere, a doc reference), fix
it — templates/docs pointing at a deleted route is a real defect, not a false positive.

- [ ] **Step 3: Commit any cleanup from Step 2** (only if Step 2 found something)

```bash
git add -A
git commit -m "Remove remaining references to the deleted plugin edit page"
```
