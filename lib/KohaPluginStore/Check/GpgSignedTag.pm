package KohaPluginStore::Check::GpgSignedTag;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use KohaPluginStore::GitHub;

sub check_name         { 'gpg_signed_tag' }
sub required            { 0 }
sub gates_certification { 0 }

sub run ($self, $extract_dir, $metadata, $context) {
    my $verified = KohaPluginStore::GitHub::fetch_tag_verification(
        $context->{github_token}, $context->{repo_url}, $context->{tag_name}
    );

    return { passed => 1, message => undef } if $verified;
    return {
        passed  => 0,
        message => 'The release tag is not GPG-signed on GitHub (informational only, does not block publishing)',
    };
}

1;
