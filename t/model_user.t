use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::User;

reset_db();

subtest 'create hashes the password' => sub {
    my $user = KohaPluginStore::Model::User->new( pg => test_pg() )->create(
        { username => 'admin', password => 'admin', email => 'admin@example.com' }
    );
    isnt( $user->password, 'admin', 'password is not stored in plain text' );
};

subtest 'check_password verifies correctly' => sub {
    KohaPluginStore::Model::User->new( pg => test_pg() )->create(
        { username => 'jdoe', password => 'secret123', email => 'jdoe@example.com' }
    );
    my $found = KohaPluginStore::Model::User->new( pg => test_pg() )->find( { username => 'jdoe' } );
    ok( $found->check_password('secret123'), 'correct password verifies' );
    ok( !$found->check_password('wrongpassword'), 'wrong password fails' );
    ok( !KohaPluginStore::Model::User->new( pg => test_pg() )->find( { username => 'nosuchuser' } ), 'unknown user is not found at all' );
};

subtest 'create requires a password' => sub {
    eval { KohaPluginStore::Model::User->new( pg => test_pg() )->create( { username => 'nopass', email => 'x@example.com' } ) };
    like( $@, qr/password is required/, 'raises without a password' );
};

done_testing();
