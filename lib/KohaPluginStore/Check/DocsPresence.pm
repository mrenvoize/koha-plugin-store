package KohaPluginStore::Check::DocsPresence;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Find;
use File::Basename qw(basename);

my @ACCEPTABLE = qw(Development.md CONTRIBUTING.md README.md README docs);

sub check_name         { 'docs_presence' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    return { passed => 1, message => undef } if _has_acceptable_entry($extract_dir);

    return {
        passed  => 0,
        message => 'No Development.md, CONTRIBUTING.md, README, or docs/ directory found',
    };
}

# .kpz archives always nest their contents under Koha/Plugin/<Vendor>/<Class>/...
# (that's what lets Koha unzip them straight into its plugins directory), so
# docs never sit at the archive root -- search the whole extracted tree.
sub _has_acceptable_entry {
    my ($extract_dir) = @_;

    return 0 unless -d $extract_dir;

    my $found = 0;
    find(
        {
            wanted => sub {
                return if $found;
                $found = 1 if grep { basename($File::Find::name) eq $_ } @ACCEPTABLE;
            },
            no_chdir => 1,
        },
        $extract_dir
    );

    return $found;
}

1;
