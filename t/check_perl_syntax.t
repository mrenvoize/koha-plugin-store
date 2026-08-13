use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::PerlSyntax;

subtest 'passes when the sandbox wrapper reports PASS for every file' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout = sub { return 1 };
    *KohaPluginStore::Check::PerlSyntax::_run_sandboxed   = sub { return "PASS Widget.pm\n" };

    my $check  = KohaPluginStore::Check::PerlSyntax->new;
    my $result = $check->run( $dir, { minimum_version => '23.05' }, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails and reports the sandboxed compile error' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget\n1;\n" );    # missing semicolon

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout = sub { return 1 };
    *KohaPluginStore::Check::PerlSyntax::_run_sandboxed   = sub {
        return "FAIL Widget.pm\nsyntax error at /plugin/Widget.pm line 2, near \"1;\"\n/plugin/Widget.pm had compilation errors.\n";
    };

    my $check  = KohaPluginStore::Check::PerlSyntax->new;
    my $result = $check->run( $dir, { minimum_version => '23.05' }, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/syntax error/, 'message includes the compile error' );
};

subtest 'runtime warnings from a real Koha checkout (no koha-conf.xml) are not mistaken for a compile error' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout = sub { return 1 };
    *KohaPluginStore::Check::PerlSyntax::_run_sandboxed   = sub {
        return "unable to locate Koha configuration file koha-conf.xml at /kohadevbox/koha/C4/Context.pm line 171.\n"
            . "PASS Widget.pm\n";
    };

    my $check  = KohaPluginStore::Check::PerlSyntax->new;
    my $result = $check->run( $dir, { minimum_version => '23.05' }, {} );
    ok( $result->{passed}, 'passed despite noisy BEGIN-time warnings preceding the PASS line' );
};

subtest 'a minimum_version that cannot be resolved to a tag fails clearly' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    my $check  = KohaPluginStore::Check::PerlSyntax->new;
    my $result = $check->run( $dir, { minimum_version => 'not-a-version' }, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/Could not resolve/, 'message explains why' );
};

subtest 'a checkout preparation failure dies as a check_infrastructure_error' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout = sub { return 0 };

    my $check = KohaPluginStore::Check::PerlSyntax->new;
    eval { $check->run( $dir, { minimum_version => '23.05' }, {} ) };
    like( $@, qr/^check_infrastructure_error/, 'dies with the infrastructure-error prefix' );
};

done_testing();
