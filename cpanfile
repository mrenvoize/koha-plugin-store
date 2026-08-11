requires 'Modern::Perl';
requires 'Mojolicious';
requires 'Mojolicious::Plugin::OpenAPI';
requires 'Mojo::Pg';
requires 'Mojolicious::Plugin::OAuth2';
requires 'Minion';
requires 'JSON';
requires 'Archive::Zip';
requires 'Digest::SHA';
requires 'String::Util';
requires 'IO::Socket::SSL';
requires 'Net::SSLeay';
requires 'File::Slurp';
# Koha::QA must be installed to a project-local 'local/' directory via:
#   cpanm -L local --force https://gitlab.com/joubu/koha-qa.git@c98c2cd6ac14756fd82edc59655b54e11c8c9f31
# Its Makefile.PL pins an exact Perl::Tidy version that would otherwise downgrade it machine-wide.
# All prove runs must be prefixed with: PERL5LIB="$(pwd)/local/lib/perl5:$PERL5LIB"
requires 'Koha::QA', git => 'https://gitlab.com/joubu/koha-qa.git', ref => 'c98c2cd6ac14756fd82edc59655b54e11c8c9f31';
requires 'Perl::Critic';
requires 'File::ShareDir';
