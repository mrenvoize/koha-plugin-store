use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::Base;

package KohaPluginStore::Check::TestDummy;
use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
sub check_name         { 'test_dummy' }
sub required            { 1 }
sub gates_certification { 1 }
sub run ($self, $extract_dir, $metadata, $context) {
    return { passed => 1, message => undef };
}
package main;

subtest 'a subclass implementing run() works' => sub {
    my $check  = KohaPluginStore::Check::TestDummy->new;
    my $result = $check->run( '/tmp', {}, {} );
    ok( $result->{passed}, 'passed is true' );
    is( $check->check_name, 'test_dummy', 'check_name accessor' );
    ok( $check->required, 'required accessor' );
    ok( $check->gates_certification, 'gates_certification accessor' );
};

subtest 'the base class dies if run() is not overridden' => sub {
    my $check = KohaPluginStore::Check::Base->new;
    eval { $check->run( '/tmp', {}, {} ) };
    like( $@, qr/must implement run/, 'dies with a clear message' );
};

subtest 'find_files finds matching files recursively' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/t");
    write_file( "$dir/Widget.pm",  "package Widget;\n1;\n" );
    write_file( "$dir/t/basic.t",  "use Test::More;\nok(1);\ndone_testing();\n" );
    write_file( "$dir/README.md",  "# Widget\n" );

    my $check    = KohaPluginStore::Check::TestDummy->new;
    my @pm_files = $check->find_files( $dir, qr/\.pm$/ );
    is( scalar @pm_files, 1, 'found exactly one .pm file' );
    like( $pm_files[0], qr/Widget\.pm$/, 'found the right file' );
};

subtest 'find_files returns an empty list for a directory that does not exist' => sub {
    my $check = KohaPluginStore::Check::TestDummy->new;
    my @found = $check->find_files( '/no/such/dir', qr/\.pm$/ );
    is( scalar @found, 0, 'empty list, not a die' );
};

done_testing();
