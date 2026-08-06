use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db);

use KohaPluginStore::Model::User;

reset_db();

subtest 'create hashes the password' => sub {
    my $user = KohaPluginStore::Model::User->new->create(
        { username => 'admin', password => 'admin', email => 'admin@example.com' }
    );
    isnt( $user->password, 'admin', 'password is not stored in plain text' );
};

subtest 'check_password verifies correctly' => sub {
    KohaPluginStore::Model::User->new->create(
        { username => 'jdoe', password => 'secret123', email => 'jdoe@example.com' }
    );
    ok( KohaPluginStore::Model::User::check_password( 'jdoe', 'secret123' ), 'correct password verifies' );
    ok( !KohaPluginStore::Model::User::check_password( 'jdoe', 'wrongpassword' ), 'wrong password fails' );
    ok( !KohaPluginStore::Model::User::check_password( 'nosuchuser', 'anything' ), 'unknown user fails' );
};

subtest 'create requires a password' => sub {
    eval { KohaPluginStore::Model::User->new->create( { username => 'nopass', email => 'x@example.com' } ) };
    like( $@, qr/password is required/, 'raises without a password' );
};

done_testing();
