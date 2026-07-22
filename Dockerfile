FROM debian:trixie-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    openssl \
    postfix \
    netcat-traditional \
    libsasl2-modules \
    sasl2-bin \
    opendkim \
    opendkim-tools \
    curl \
    socat \
    ca-certificates && \
    # acme.sh replaces certbot: a single shell script with no Python
    # dependency stack (removes the urllib3/cryptography CVE surface).
    curl -fsSL https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz -o /tmp/acme.tar.gz && \
    mkdir -p /tmp/acme && tar xzf /tmp/acme.tar.gz -C /tmp/acme --strip-components=1 && \
    (cd /tmp/acme && ./acme.sh --install --home /opt/acme.sh --nocron --noprofile) && \
    rm -rf /tmp/acme /tmp/acme.tar.gz /var/lib/apt/lists/*

FROM debian:trixie-slim

COPY --from=builder /usr/lib /usr/lib
COPY --from=builder /usr/bin /usr/bin
COPY --from=builder /usr/sbin /usr/sbin
COPY --from=builder /usr/share/postfix /usr/share/postfix
COPY --from=builder /usr/share/ca-certificates /usr/share/ca-certificates
COPY --from=builder /etc/postfix /etc/postfix
COPY --from=builder /etc/ssl/ /etc/ssl/
COPY --from=builder /etc/alternatives /etc/alternatives
COPY --from=builder /etc/ca-certificates.conf /etc/ca-certificates.conf
COPY --from=builder /opt/acme.sh /opt/acme.sh

# Patch base packages (glibc, perl-base, etc.) registered in the slim base
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

# Postfix configuration
COPY config/main.cf /etc/postfix/main.cf
COPY config/master.cf /etc/postfix/master.cf

# OpenDKIM configuration
COPY config/opendkim.conf /etc/opendkim.conf
COPY config/opendkim/ /etc/opendkim/

# TLS certificate generation
COPY certs/ca-openssl.cnf.tpl /etc/ssl/
COPY certs/postfix-openssl.cnf.tpl /etc/ssl/
COPY certs/certgen.sh /usr/local/bin/

COPY docker-entrypoint.sh /

RUN groupadd -g 89 postfix && \
    groupadd -g 90 postdrop && \
    useradd -g postfix -u 89 -d /var/spool/postfix postfix && \
    useradd -g postdrop -u 90 -d /var/spool/postfix postdrop && \
    groupadd -g 91 opendkim && \
    useradd -g opendkim -u 91 -d /var/run/opendkim -s /usr/sbin/nologin opendkim && \
    mkdir -p /var/spool/postfix /var/lib/postfix /etc/sasl2 \
             /var/run/opendkim /etc/ssl/dkim /etc/opendkim && \
    chown opendkim:opendkim /var/run/opendkim /etc/ssl/dkim && \
    touch /etc/aliases && \
    newaliases && \
    chmod +x /usr/local/bin/certgen.sh /docker-entrypoint.sh

EXPOSE 25/tcp 587/tcp

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["/usr/sbin/postfix", "start-fg"]
