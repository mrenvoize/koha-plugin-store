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
