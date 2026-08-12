package KohaPluginStore::Check::PerlSyntax;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Fcntl qw(:flock);

my $DEFAULT_CACHE_DIR = '/var/cache/koha-plugin-store/koha-checkouts';
my $DEFAULT_GIT_URL   = 'https://git.koha-community.org/Koha-community/Koha.git';

sub check_name         { 'perl_syntax' }
sub required            { 1 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my $tag = _resolve_tag( $metadata->{minimum_version} );
    unless ($tag) {
        return {
            passed  => 0,
            message => "Could not resolve a Koha release tag for minimum_version '"
                . ( $metadata->{minimum_version} // '' ) . "'",
        };
    }

    my $cache_dir     = $context->{koha_checkout_cache_dir} // $DEFAULT_CACHE_DIR;
    my $git_url       = $context->{koha_git_url}            // $DEFAULT_GIT_URL;
    my $checkout_dir  = "$cache_dir/$tag";

    unless ( _ensure_checkout( $tag, $checkout_dir, $git_url ) ) {
        die "check_infrastructure_error: could not prepare Koha checkout for tag $tag\n";
    }

    my @pm_files = $self->find_files( $extract_dir, qr/\.pm$/ );

    return { passed => 1, message => undef } unless @pm_files;

    my $output = _run_sandboxed( $checkout_dir, $extract_dir, \@pm_files );

    my @errors = grep { length && !/syntax OK$/ } split /\n/, $output;

    return { passed => 1, message => undef } unless @errors;
    return { passed => 0, message => join( '; ', @errors ) };
}

sub _resolve_tag {
    my ($minimum_version) = @_;
    return unless $minimum_version;
    return "v$minimum_version" if $minimum_version =~ /^\d+\.\d+(\.\d+)?$/;
    return;
}

# Test seam: overridden in tests to avoid a real git clone.
sub _ensure_checkout {
    my ( $tag, $checkout_dir, $git_url ) = @_;

    return 1 if -d $checkout_dir;

    make_path( dirname($checkout_dir) );
    my $lock_file = "$checkout_dir.lock";
    open my $lock_fh, '>', $lock_file or return 0;
    flock( $lock_fh, LOCK_EX );

    return 1 if -d $checkout_dir;    # another process won the race while we waited

    my $ok = system( 'git', 'clone', '--depth', '1', '--branch', $tag, $git_url, $checkout_dir ) == 0;

    close $lock_fh;
    unlink $lock_file;

    return $ok;
}

# Pure command builder, split out from _run_sandboxed so the exact argv list
# handed to exec() can be asserted on without forking/execing docker. Returns
# a flat list -- NOT a shell string -- so no path or generated $script content
# is ever parsed by a shell, however many quotes or slashes it contains.
sub _build_sandbox_cmd {
    my ( $checkout_dir, $extract_dir, $pm_files ) = @_;

    my @relative = map { my $f = $_; $f =~ s{^\Q$extract_dir\E/?}{}; $f } @$pm_files;
    my $script   = join( '; ', map { qq{system('perl', '-I/koha/lib', '-cw', '/plugin/$_')} } @relative );

    return (
        'timeout', '--signal=KILL', '30',
        'docker', 'run', '--rm', '--network', 'none',
        '--memory', '256m', '--cpus', '0.5', '--read-only', '--tmpfs', '/tmp',
        '-v', "$checkout_dir:/koha:ro",
        '-v', "$extract_dir:/plugin:ro",
        'perl:5.38-slim',
        'perl', '-e', $script,
    );
}

# Test seam: overridden in tests to avoid needing Docker.
#
# Wrapped in `timeout --signal=KILL` so a plugin file that hangs the compiler
# (e.g. an infinite BEGIN loop) can't tie up a Minion worker forever -- a
# timeout here is treated by run() as ordinary output (no "syntax OK" line
# survives it), so it fails PerlSyntax like any other compile error, not as a
# check_infrastructure_error. Known follow-up: a hard-killed `docker run`
# client can in rare cases leave the container itself running past the
# timeout since --rm only cleans up on normal exit; revisit with an explicit
# `docker kill` sweep if that's observed in practice.
#
# Runs docker directly via fork+exec (no shell) -- the previous version built
# this as one big backtick-executed shell string, and $script's own single
# quotes (from the per-file `system('perl', ...)` calls) broke out of the
# outer `perl -e '$script'` shell quoting for any plugin at all, corrupting
# the command the sandbox actually ran.
sub _run_sandboxed {
    my ( $checkout_dir, $extract_dir, $pm_files ) = @_;

    my @cmd = _build_sandbox_cmd( $checkout_dir, $extract_dir, $pm_files );

    my $pid = open( my $fh, '-|' );
    die "Could not fork: $!\n" unless defined $pid;

    if ( $pid == 0 ) {
        open( STDERR, '>&STDOUT' ) or die "Could not redirect STDERR: $!\n";
        exec(@cmd) or die "Could not exec docker: $!\n";
    }

    local $/;
    my $output = <$fh> // '';
    close $fh;

    return $output;
}

1;
