use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::HardcodedCredentials;

subtest 'passes plain plugin code' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\n1;\n" );

    my $check  = KohaPluginStore::Check::HardcodedCredentials->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails on a hardcoded password literal' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nmy \%opts = ( password => 'sup3rSecret!' );\n1;\n" );

    my $check  = KohaPluginStore::Check::HardcodedCredentials->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/Widget\.pm/, 'message names the file' );
};

subtest 'fails on an AWS-access-key-shaped string' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nmy \$key = 'AKIAABCDEFGHIJKLMNOP';\n1;\n" );

    my $check  = KohaPluginStore::Check::HardcodedCredentials->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

done_testing();
