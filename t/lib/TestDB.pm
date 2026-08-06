package TestDB;

use Modern::Perl;
use Exporter 'import';

use KohaPluginStore::Model::DB;

our @EXPORT_OK = qw(reset_db);

my $DSN = $ENV{KOHA_PLUGIN_STORE_TEST_DSN}
    || 'postgresql://koha_plugin_store:koha_plugin_store@127.0.0.1:55432/koha_plugin_store';

KohaPluginStore::Model::DB->pg( { pg_dsn => $DSN } );

sub reset_db {
    KohaPluginStore::Model::DB->pg->db->query(
        'TRUNCATE plugin_versions, plugins, users RESTART IDENTITY CASCADE'
    );
}

1;
