package KohaPluginStore::Model::DB;

use Modern::Perl;
use Carp qw( croak );
use Mojo::Pg;

my $pg;

sub pg {
    my ( $class, $config ) = @_;

    return $pg if $pg;

    croak('pg_dsn is required (pass a config hashref on the first call)')
        unless $config && $config->{pg_dsn};

    $pg = Mojo::Pg->new( $config->{pg_dsn} );

    return $pg;
}

1;
