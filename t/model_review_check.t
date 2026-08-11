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
