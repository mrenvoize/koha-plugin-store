package KohaPluginStore::Model::User;

use Modern::Perl;
use Carp ();
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

use Passwords ();

sub _table {
    return 'users';
}

sub _columns {
    return [qw(id username password email)];
}

sub check_password {
    my ( $username, $password ) = @_;

    return undef unless $password;
    my $user = KohaPluginStore::Model::User->new->find( { username => $username } );

    return undef unless $user;
    return Passwords::password_verify( $password, $user->password );
}

sub create {
    my ( $self, $attrs ) = @_;

    Carp::croak('password is required') unless $attrs->{password};
    $attrs->{password} = Passwords::password_hash( $attrs->{password} );

    return $self->SUPER::create($attrs);
}

1;
