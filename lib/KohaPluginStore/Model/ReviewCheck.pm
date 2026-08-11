package KohaPluginStore::Model::ReviewCheck;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

sub _table {
    return 'review_checks';
}

sub _columns {
    return [qw(id plugin_version_id check_name required passed message checked_at)];
}

sub record {
    my ( $self, $attrs ) = @_;

    my $row = $self->pg->db->query(
        q{
            INSERT INTO review_checks (plugin_version_id, check_name, required, passed, message)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (plugin_version_id, check_name)
            DO UPDATE SET passed = EXCLUDED.passed, message = EXCLUDED.message, checked_at = now()
            RETURNING *
        },
        $attrs->{plugin_version_id}, $attrs->{check_name}, $attrs->{required} ? 1 : 0,
        $attrs->{passed} ? 1 : 0, $attrs->{message}
    )->hash;

    return $self->_new_from_row($row);
}

1;
