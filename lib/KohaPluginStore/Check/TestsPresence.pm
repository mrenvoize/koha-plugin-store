package KohaPluginStore::Check::TestsPresence;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;

sub check_name         { 'tests_presence' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @t_files = $self->find_files( "$extract_dir/t", qr/\.t$/ );

    return { passed => 1, message => undef } if @t_files;
    return { passed => 0, message => 'No test files (t/*.t) found' };
}

1;
