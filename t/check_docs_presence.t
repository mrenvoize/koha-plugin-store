use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::DocsPresence;

subtest 'passes when Development.md is present' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Development.md", "# Development\n" );

    my $check  = KohaPluginStore::Check::DocsPresence->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'passes when README.md is present' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/README.md", "# Widget\n" );

    my $check  = KohaPluginStore::Check::DocsPresence->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails when nothing documents the plugin' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    my $check  = KohaPluginStore::Check::DocsPresence->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

done_testing();
