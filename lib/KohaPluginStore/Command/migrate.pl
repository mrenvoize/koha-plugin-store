#!/usr/bin/env perl
use Modern::Perl;
use Mojo::File qw(curfile);
use Mojo::Pg;

# Navigate from lib/KohaPluginStore/Command/ to project root (four dirname() calls because Mojo::File's sibling() takes a sibling filename, not '..' for parent navigation)
my $root        = curfile->dirname->dirname->dirname->dirname;
my $config_file = $root->child('koha_plugin_store.conf');
my $config      = -e $config_file ? do "$config_file" : undef;

my $dsn = $ENV{KOHA_PLUGIN_STORE_PG_DSN}
    || ( $config && $config->{pg_dsn} )
    || 'postgresql://koha_plugin_store:koha_plugin_store@127.0.0.1:55432/koha_plugin_store';

my $pg = Mojo::Pg->new($dsn);
$pg->migrations->from_file( $root->child('migrations', 'koha_plugin_store.sql') )->migrate;

say 'Migrated to version ' . $pg->migrations->latest;
