package KohaPluginStore::Model::Base;

use Modern::Perl;
use Carp qw( croak );

use KohaPluginStore::Model::DB;

sub new {
    my ($class) = @_;
    return bless { _data => undef }, $class;
}

sub _pg {
    return KohaPluginStore::Model::DB->pg;
}

sub default_query_params {
    return { limit => 10 };
}

sub create {
    my ( $self, $attrs ) = @_;

    my $row = $self->_pg->db->insert(
        $self->_table, $attrs, { returning => $self->_columns }
    )->hash;

    return $self->_new_from_row($row);
}

sub find {
    my ( $self, $query ) = @_;

    my $row = $self->_pg->db->select( $self->_table, undef, $query, { limit => 1 } )->hash;
    return unless $row;

    return $self->_new_from_row($row);
}

sub search {
    my ( $self, $query, $params ) = @_;

    $query = {} unless $query;
    my $merged = { %{ $self->default_query_params }, %{ $params || {} } };

    my $rows = $self->_pg->db->select( $self->_table, undef, $query, $merged )->hashes;

    return map { $self->_new_from_row($_) } @$rows;
}

sub _new_from_row {
    my ( $self, $row ) = @_;
    return bless { _data => $row }, ref($self) || $self;
}

sub unblessed {
    my ($self) = @_;
    return { %{ $self->{_data} } };
}

our $AUTOLOAD;

sub AUTOLOAD {
    my $self = shift;

    my $method = $AUTOLOAD;
    $method =~ s/.*:://;
    return if $method eq 'DESTROY';

    croak( $method . ' is not a column on ' . $self->_table )
        unless $self->{_data} && exists $self->{_data}{$method};

    if (@_) {
        $self->{_data}{$method} = shift;
        return $self;
    }

    return $self->{_data}{$method};
}

1;
