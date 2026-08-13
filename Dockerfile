FROM perl:5.36-slim

# docker.io gives us the `docker` CLI the worker's PerlSyntax check shells out
# to (against the host's socket, mounted in by docker-compose.yml) -- Debian
# bundles dockerd in the same package, but nothing here ever starts it.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    git \
    nodejs \
    npm \
    docker.io \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g yarn

WORKDIR /app

COPY cpanfile ./
# Koha::QA isn't on CPAN, and plain `cpanm --installdeps` ignores the cpanfile's
# git => meta entirely (it always does a bare CPAN name lookup for that line,
# which fails) -- so install it explicitly first, the same way the cpanfile's
# own comment documents, then run installdeps against a copy of the cpanfile
# with that line stripped so it isn't attempted (and failed) a second time.
# Its Makefile.PL needs Module::CPANfile/File::ShareDir::Install to configure
# and yarn to build its share/ assets. It also pins an exact Perl::Tidy
# version, which Perl::Critic's own (unpinned) dependency resolution will
# otherwise clobber with whatever's newest -- `-L local` doesn't reliably see
# a Perl::Tidy/Perl::Critic already installed outside that lib, so pin both
# *inside* -L local, immediately before the koha-qa install, not just site-wide.
RUN cpanm --notest Module::CPANfile File::ShareDir::Install \
    && cpanm -L local --notest --force Perl::Tidy@20250105 Perl::Critic \
    && cpanm -L local --notest --force https://gitlab.com/joubu/koha-qa.git@c98c2cd6ac14756fd82edc59655b54e11c8c9f31 \
    && grep -v 'Koha::QA' cpanfile > cpanfile.rest \
    && cpanm --cpanfile cpanfile.rest --installdeps --notest .
ENV PERL5LIB=/app/local/lib/perl5

COPY . .

EXPOSE 3000

CMD ["morbo", "--listen", "http://*:3000", "script/koha_plugin_store"]
