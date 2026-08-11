use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::DependencyAllowlist;

subtest 'passes plain plugin code' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\nsub install { return 1 }\n1;\n" );

    my $check  = KohaPluginStore::Check::DependencyAllowlist->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails and names the file when system() is called' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\nsystem('rm -rf /tmp/x');\n1;\n" );

    my $check  = KohaPluginStore::Check::DependencyAllowlist->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/Widget\.pm/,    'message names the file' );
    like( $result->{message}, qr/system\(\)/,    'message names the pattern' );
};

subtest 'fails on filesystem access outside the plugin directory' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\nopen(my \$fh, '<', '../../etc/passwd');\n1;\n" );

    my $check  = KohaPluginStore::Check::DependencyAllowlist->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

done_testing();
