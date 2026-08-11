package KohaPluginStore::Check::ManifestCompleteness;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;

sub check_name         { 'manifest_completeness' }
sub required            { 1 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @missing;
    push @missing, 'version' unless $metadata->{version};
    push @missing, 'license' unless $metadata->{license};

    return { passed => 1, message => undef } unless @missing;

    return {
        passed  => 0,
        message => 'Plugin metadata is missing required field(s): ' . join( ', ', @missing ),
    };
}

1;
