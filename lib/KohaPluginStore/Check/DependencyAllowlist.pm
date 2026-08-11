package KohaPluginStore::Check::DependencyAllowlist;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Slurp qw(read_file);

# Known limitation: the open() pattern will also match some relative paths like open($fh, '<', 'templates/foo.tt')
# because a static regex cannot distinguish absolute vs relative without heavier dynamic analysis (deferred as future work).
my @RISKY_PATTERNS = (
    [ qr/\bsystem\s*\(/,               'calls system()' ],
    [ qr/\bexec\s*\(/,                 'calls exec()' ],
    [ qr/`[^`]*`/,                     'uses backticks' ],
    [ qr/\bqx\s*[\(\{\[\/]/,           'uses qx//' ],
    [ qr/\buse\s+IO::Socket/,          'opens sockets (IO::Socket)' ],
    [ qr/\buse\s+Net::\w+/,            'uses a Net:: networking module' ],
    [ qr/\buse\s+(LWP|HTTP::Tiny)\b/,  'makes HTTP requests' ],
    [ qr/\bopen\s*\(.*['"]\s*\//,      'opens an absolute filesystem path' ],
    [ qr/\.\.\//,                      'references a path outside its own directory (../)' ],
);

sub check_name         { 'dependency_allowlist' }
sub required            { 1 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @issues;

    for my $file ( $self->find_files( $extract_dir, qr/\.(pm|pl)$/ ) ) {
        my $content  = read_file($file);
        my $relative = $file;
        $relative =~ s{^\Q$extract_dir\E/?}{};

        for my $pattern (@RISKY_PATTERNS) {
            my ( $re, $description ) = @$pattern;
            push @issues, "$relative: $description" if $content =~ $re;
        }
    }

    return { passed => 1, message => undef } unless @issues;
    return { passed => 0, message => join( '; ', @issues ) };
}

1;
