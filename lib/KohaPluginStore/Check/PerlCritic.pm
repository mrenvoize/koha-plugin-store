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
