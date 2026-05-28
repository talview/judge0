FROM talview.azurecr.io/judge0-compilers:bookworm-20260528-2285831 AS production

ENV JUDGE0_HOMEPAGE "https://judge0.com"
LABEL homepage=$JUDGE0_HOMEPAGE

ENV JUDGE0_SOURCE_CODE "https://github.com/judge0/judge0"
LABEL source_code=$JUDGE0_SOURCE_CODE

ENV JUDGE0_MAINTAINER "Herman Zvonimir Došilović <hermanz.dosilovic@gmail.com>"
LABEL maintainer=$JUDGE0_MAINTAINER

# Judge0 v1.13.1 runs on Rails 5.2 / Ruby 2.7. The bookworm compilers image
# ships Ruby 3.3.7 (for user submissions) but not 2.7 — Ruby 2.7's ext/openssl
# can't compile against bookworm's OpenSSL 3. Build OpenSSL 1.1.1w + Ruby
# 2.7.8 here, isolated under /usr/local/, so the Rails app has a Ruby it can
# actually use without disturbing the compilers image.
# Drop this whole step once Judge0 is upgraded off Rails 5.
RUN set -xe && \
    curl -fSsLo /tmp/openssl.tar.gz https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz && \
    mkdir /tmp/openssl && \
    tar -xf /tmp/openssl.tar.gz -C /tmp/openssl --strip-components=1 && \
    rm /tmp/openssl.tar.gz && \
    cd /tmp/openssl && \
    ./config --prefix=/usr/local/openssl-1.1.1w --openssldir=/usr/local/openssl-1.1.1w shared zlib && \
    make -j$(nproc) && \
    make -j$(nproc) install_sw && \
    rm -rf /tmp/openssl && \
    curl -fSsLo /tmp/ruby-2.7.8.tar.gz https://cache.ruby-lang.org/pub/ruby/2.7/ruby-2.7.8.tar.gz && \
    mkdir /tmp/ruby-2.7.8 && \
    tar -xf /tmp/ruby-2.7.8.tar.gz -C /tmp/ruby-2.7.8 --strip-components=1 && \
    rm /tmp/ruby-2.7.8.tar.gz && \
    cd /tmp/ruby-2.7.8 && \
    ./configure --disable-install-doc --prefix=/usr/local/ruby-2.7.8 \
      --with-openssl-dir=/usr/local/openssl-1.1.1w && \
    make -j$(nproc) && \
    make -j$(nproc) install && \
    rm -rf /tmp/*

ENV PATH="/usr/local/ruby-2.7.8/bin:/opt/.gem/bin:$PATH"
ENV GEM_HOME="/opt/.gem/"
ENV LD_LIBRARY_PATH="/usr/local/openssl-1.1.1w/lib"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      cron \
      libpq-dev \
      sudo && \
    rm -rf /var/lib/apt/lists/* && \
    echo "gem: --no-document" > /root/.gemrc && \
    gem install bundler:2.1.4 && \
    npm install -g --unsafe-perm aglio@2.3.0

EXPOSE 2358

WORKDIR /api

COPY Gemfile* ./
RUN RAILS_ENV=production bundle

COPY cron /etc/cron.d
RUN cat /etc/cron.d/* | crontab -

COPY . .

ENTRYPOINT ["/api/docker-entrypoint.sh"]
CMD ["/api/scripts/server"]

RUN useradd -u 1000 -m -r judge0 && \
    echo "judge0 ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers && \
    chown judge0: /api/tmp/

USER judge0

ENV JUDGE0_VERSION "1.13.1"
LABEL version=$JUDGE0_VERSION


FROM production AS development

CMD ["sleep", "infinity"]
