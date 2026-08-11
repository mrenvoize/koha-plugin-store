package KohaPluginStore::Check::Base;

use Mojo::Base -base, -signatures;
use File::Find;

sub run ($self, $extract_dir, $metadata, $context) {
    die ref($self) . ' must implement run()';
}

sub find_files ($self, $dir, $pattern) {
    return () unless -d $dir;

    my @matches;
    find(
        {
            wanted   => sub { push @matches, $File::Find::name if -f $_ && /$pattern/ },
            no_chdir => 1,
        },
        $dir
    );

    return @matches;
}

1;
