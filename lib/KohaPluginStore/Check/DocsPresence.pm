package KohaPluginStore::Check::DocsPresence;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;

my @ACCEPTABLE = qw(Development.md CONTRIBUTING.md README.md README docs);

sub check_name         { 'docs_presence' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    for my $name (@ACCEPTABLE) {
        return { passed => 1, message => undef } if -e "$extract_dir/$name";
    }

    return {
        passed  => 0,
        message => 'No Development.md, CONTRIBUTING.md, README, or docs/ directory found',
    };
}

1;
