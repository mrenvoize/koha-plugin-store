package KohaPluginStore::Check::TranslatableTemplates;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Slurp qw(read_file);

# Heuristic, not exhaustive: flags .tt files that render visible text but never
# call Koha's translation marker anywhere in the file. Doesn't inspect
# individual strings -- a file using t() even once is treated as translated.
sub check_name         { 'translatable_templates' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @untranslated;

    for my $file ( $self->find_files( $extract_dir, qr/\.tt$/ ) ) {
        my $content = read_file($file);
        next unless $content =~ /<(h1|h2|h3|p|label|button|span|td|th)\b/i;

        unless ( $content =~ /\[%[-~]?\s*t\s*\(/ ) {
            my $relative = $file;
            $relative =~ s{^\Q$extract_dir\E/?}{};
            push @untranslated, $relative;
        }
    }

    return { passed => 1, message => undef } unless @untranslated;

    return {
        passed  => 0,
        message => 'Template(s) render text but never use the [% t(...) %] translation marker: '
            . join( ', ', @untranslated ),
    };
}

1;
