use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

subtest 'register then login' => sub {
    $t->post_ok(
        '/register' => form => {
            username => 'newdev',
            password => 'devpassword',
            email    => 'newdev@example.com',
        }
    )->status_is(302);

    $t->get_ok('/logout')->status_is(302);

    $t->post_ok(
        '/login' => form => { username => 'newdev', password => 'devpassword' }
    )->status_is(302);
};

subtest 'my-plugins requires login' => sub {
    $t->get_ok('/logout')->status_is(302);
    $t->get_ok('/my-plugins')->status_is(404); # existing #TODO in the app: this should be 401
};

done_testing();
