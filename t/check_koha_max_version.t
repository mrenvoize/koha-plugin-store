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
