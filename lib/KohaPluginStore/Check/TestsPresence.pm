package KohaPluginStore::Check::TestsPresence;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Basename qw(basename dirname);

sub check_name         { 'tests_presence' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    # .kpz archives always nest their contents under Koha/Plugin/<Vendor>/<Class>/...,
    # so a plugin's t/ directory never sits at the archive root -- search the
    # whole extracted tree for a "t" directory holding .t files, not just
    # "$extract_dir/t".
    my @t_files = grep { basename( dirname($_) ) eq 't' } $self->find_files( $extract_dir, qr/\.t$/ );

    return { passed => 1, message => undef } if @t_files;
    return { passed => 0, message => 'No test files (t/*.t) found' };
}

1;
