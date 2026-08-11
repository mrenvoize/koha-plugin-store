use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::Check::GpgSignedTag;

subtest 'passes when the tag is GPG-verified' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_tag_verification = sub { return 1 };

    my $check  = KohaPluginStore::Check::GpgSignedTag->new;
    my $result = $check->run( '/unused', {}, { github_token => 't', repo_url => 'https://github.com/dev/widget', tag_name => 'v1.0.0' } );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails, but is non-gating, when the tag is not verified' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_tag_verification = sub { return 0 };

    my $check  = KohaPluginStore::Check::GpgSignedTag->new;
    my $result = $check->run( '/unused', {}, { github_token => 't', repo_url => 'https://github.com/dev/widget', tag_name => 'v1.0.0' } );
    ok( !$result->{passed}, 'failed' );
    ok( !$check->gates_certification, 'does not gate certification' );
};

done_testing();
