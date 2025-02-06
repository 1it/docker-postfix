FROM debian:bookworm-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    openssl \
    postfix \
    netcat-traditional \
    libsasl2-modules \
    ca-certificates 

FROM debian:bookworm-slim

COPY --from=builder /usr/lib /usr/lib
COPY --from=builder /usr/bin /usr/bin
COPY --from=builder /usr/sbin /usr/sbin
COPY --from=builder /usr/share/postfix /usr/share/postfix
COPY --from=builder /usr/share/ca-certificates /usr/share/ca-certificates
COPY --from=builder /etc/postfix /etc/postfix
COPY --from=builder /etc/ssl/ /etc/ssl/
COPY --from=builder /etc/alternatives /etc/alternatives
COPY --from=builder /etc/ca-certificates.conf /etc/ca-certificates.conf

COPY config /etc/postfix/
COPY certs/ca-openssl.cnf.tpl /etc/ssl/
COPY certs/postfix-openssl.cnf.tpl /etc/ssl/
COPY certs/certgen.sh /usr/local/bin/   
COPY docker-entrypoint.sh /

RUN groupadd -g 89 postfix && \
    groupadd -g 90 postdrop && \
    useradd -g postfix -u 89 -d /var/spool/postfix postfix && \
    useradd -g postdrop -u 90 -d /var/spool/postfix postdrop && \
    mkdir -p /var/spool/postfix /var/lib/postfix /etc/sasl2 && \
    touch /etc/aliases && \
    newaliases && \
    chmod +x /usr/local/bin/certgen.sh /docker-entrypoint.sh

EXPOSE 25/tcp 465/tcp 587/tcp

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["/usr/sbin/postfix", "start-fg"]
