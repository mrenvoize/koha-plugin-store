package KohaPluginStore::Check::HardcodedCredentials;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Slurp qw(read_file);

my @PATTERNS = (
    qr/\b(?:api[_-]?key|secret|token|password|passwd)\s*(?:=>|=)\s*['"][^'"]{6,}['"]/i,
    qr/-----BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY-----/,
    qr/\bAKIA[0-9A-Z]{16}\b/,    # AWS access key ID shape
);

sub check_name         { 'hardcoded_credentials' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @hits;

    for my $file ( $self->find_files( $extract_dir, qr/\.(pm|pl|tt)$/ ) ) {
        my $content = read_file($file);
        for my $pattern (@PATTERNS) {
            if ( $content =~ $pattern ) {
                my $relative = $file;
                $relative =~ s{^\Q$extract_dir\E/?}{};
                push @hits, $relative;
                last;
            }
        }
    }

    return { passed => 1, message => undef } unless @hits;
    return { passed => 0, message => 'Possible hardcoded credential(s) found in: ' . join( ', ', @hits ) };
}

1;
