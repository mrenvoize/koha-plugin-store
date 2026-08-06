package KohaPluginStore::Command::migrate;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::Model::DB;

has description => 'Apply Postgres migrations';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $pg = KohaPluginStore::Model::DB->pg;
    $pg->migrations->from_data(__PACKAGE__)->migrate;

    say 'Migrated to version ' . $pg->migrations->latest;
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::migrate - Apply Postgres migrations

=head1 SYNOPSIS

  Usage: APPLICATION migrate

=cut

__DATA__

@@ migrations
-- 1 up
CREATE TABLE users (
    id       SERIAL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    email    TEXT UNIQUE NOT NULL
);

CREATE TABLE plugins (
    id          SERIAL PRIMARY KEY,
    repo_url    TEXT UNIQUE,
    name        TEXT UNIQUE,
    class_name  TEXT UNIQUE,
    description TEXT,
    author      TEXT,
    thumbnail   TEXT,
    user_id     INTEGER REFERENCES users(id) ON DELETE CASCADE,
    "timestamp" TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE plugin_versions (
    id               SERIAL PRIMARY KEY,
    plugin_id        INTEGER REFERENCES plugins(id) ON DELETE CASCADE,
    name             TEXT,
    tag_name         TEXT,
    version          TEXT,
    koha_min_version TEXT,
    kpz_url          TEXT,
    date_released    TIMESTAMPTZ
);

-- 1 down
DROP TABLE plugin_versions;
DROP TABLE plugins;
DROP TABLE users;
