package KohaPluginStore::Check::PluginTemplateWrapper;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Slurp qw(read_file);

# NOTE: the exact Koha plugin template wrapper include name below is a
# best-effort placeholder pending confirmation against Koha::Plugins
# documentation -- update this constant, not the surrounding logic, once
# confirmed.
my $REQUIRED_INCLUDE = 'doc-head-close.inc';

sub check_name         { 'plugin_template_wrapper' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @missing;

    for my $file ( $self->find_files( $extract_dir, qr/\.tt$/ ) ) {
        my $content = read_file($file);
        unless ( $content =~ /INCLUDE\s+['"]\Q$REQUIRED_INCLUDE\E['"]/ ) {
            my $relative = $file;
            $relative =~ s{^\Q$extract_dir\E/?}{};
            push @missing, $relative;
        }
    }

    return { passed => 1, message => undef } unless @missing;

    return {
        passed  => 0,
        message => "Template(s) missing the '$REQUIRED_INCLUDE' plugin wrapper include: " . join( ', ', @missing ),
    };
}

1;
