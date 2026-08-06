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
