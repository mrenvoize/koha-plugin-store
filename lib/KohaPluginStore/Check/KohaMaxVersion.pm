package KohaPluginStore::Check::KohaMaxVersion;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;

sub check_name         { 'koha_max_version' }
sub required            { 0 }
sub gates_certification { 0 }

sub run ($self, $extract_dir, $metadata, $context) {
    return { passed => 1, message => undef } if $metadata->{maximum_version};
    return {
        passed  => 0,
        message => 'metadata does not declare maximum_version (recommended, does not block publishing)',
    };
}

1;
