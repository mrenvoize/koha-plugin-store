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
