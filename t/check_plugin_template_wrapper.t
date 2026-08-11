use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::PluginTemplateWrapper;

subtest 'passes a template that includes the wrapper' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/page.tt", "[% INCLUDE 'doc-head-close.inc' %]\n<h1>Hello</h1>\n" );

    my $check  = KohaPluginStore::Check::PluginTemplateWrapper->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'passes when there are no templates at all' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    my $check  = KohaPluginStore::Check::PluginTemplateWrapper->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails a template missing the wrapper include' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/page.tt", "<h1>Hello</h1>\n" );

    my $check  = KohaPluginStore::Check::PluginTemplateWrapper->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/page\.tt/, 'message names the file' );
};

done_testing();
