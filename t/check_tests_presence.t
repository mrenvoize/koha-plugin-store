use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::TestsPresence;

subtest 'passes when t/ has at least one .t file' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/t");
    write_file( "$dir/t/basic.t", "use Test::More;\nok(1);\ndone_testing();\n" );

    my $check  = KohaPluginStore::Check::TestsPresence->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails when there is no t/ directory' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    my $check  = KohaPluginStore::Check::TestsPresence->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

subtest 'fails when t/ exists but is empty' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/t");

    my $check  = KohaPluginStore::Check::TestsPresence->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

done_testing();
