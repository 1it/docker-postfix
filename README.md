# Postfix Docker Image

[![Docker Pulls](https://img.shields.io/docker/pulls/01it/postfix.svg)](https://hub.docker.com/r/01it/postfix)
[![Docker Stars](https://img.shields.io/docker/stars/01it/postfix.svg)](https://hub.docker.com/r/01it/postfix)
[![GitHub release](https://img.shields.io/github/release/1it/docker-postfix.svg)](https://github.com/1it/docker-postfix/releases)

Lightweight Postfix mail relay with built-in DKIM signing, TLS support, and flexible delivery modes.

## Features

- **Direct delivery** — send mail directly to recipient MX servers (default)
- **Relay mode** — forward mail through an external SMTP provider (AWS SES, Gmail, etc.)
- **DKIM signing** — embedded OpenDKIM with automatic key generation
- **TLS** — auto-generated self-signed certs, Let's Encrypt, or certificates you provide
- **Configurable** — all settings via environment variables
- **Minimal** — multi-stage Debian Trixie build
- **Multi-arch** — `linux/amd64` and `linux/arm64`

## Quick Start

```bash
docker run -d --name postfix \
  -e DOMAIN=example.com \
  -e MAILNAME=mail.example.com \
  -p 25:25 -p 587:587 \
  -v dkim_keys:/etc/ssl/dkim \
  01it/postfix:latest
```

On first startup, the container will:
1. Generate a DKIM key pair and print the DNS TXT record to stdout
2. Generate self-signed TLS certificates
3. Start OpenDKIM and Postfix

Check logs for the DKIM public key:
```bash
docker logs postfix 2>&1 | grep -A2 "DKIM PUBLIC KEY"
```

## Operation Modes

### Direct Delivery (default)

Mail is delivered directly to recipient MX servers over port 25. This is the default when `RELAY_HOST` is not set.

Requirements:
- Outbound port 25 must be open (blocked by most cloud providers by default)
- Proper DNS records configured (see [DNS Records](#dns-records))

### Relay Mode

Mail is forwarded through an external SMTP provider. Activated by setting `RELAY_HOST`.

Keep `SMTP_USERNAME` and `SMTP_PASSWORD` in a gitignored `.env` file and
reference them from Compose. Do not write passwords into `docker-compose.yml`.

```yaml
environment:
  RELAY_HOST: "[smtp.example.com]:587"
  SMTP_USERNAME: ${SMTP_USERNAME}
  SMTP_PASSWORD: ${SMTP_PASSWORD}
```

### Authenticated Submission

Port 587 always requires a SASL account from `SMTP_AUTH_USERS`, including
clients inside `MY_NETWORKS`. Trusted networks can still relay without a
login on port 25.

Store the account list in a gitignored `.env` (mode `600`). Compose
substitutes `${SMTP_AUTH_USERS}` from that file. The password still reaches
the container as an environment variable, so `docker inspect` can show it;
the value does not belong in the compose file, the image, or git. A comma
separates accounts. A password must not contain a comma.

```bash
# .env
SMTP_AUTH_USERS=alice:<long-random-secret>
```

```yaml
services:
  postfix:
    environment:
      SMTP_AUTH_USERS: ${SMTP_AUTH_USERS:?set SMTP_AUTH_USERS in .env}
    ports:
      - "587:587"
```

Clients authenticate over STARTTLS with the bare username (for example
`alice`) and the password from `.env`. Accounts are re-provisioned on every
start, so change `.env` and recreate the container to rotate credentials.

## Configuration

### Core Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `DOMAIN` | `example.com` | Domain for DKIM signing |
| `MAILNAME` | `mail.example.com` | Postfix hostname (`myhostname`) and Let's Encrypt certificate name |
| `MY_NETWORKS` | `127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16` | Trusted networks allowed to relay on port 25 |
| `MY_DESTINATION_DOMAINS` | — | Additional local destination domains |
| `SMTP_AUTH_USERS` | — | Submission (587) accounts, `user:password` pairs separated by commas. Set this in a gitignored env file. |

### DKIM Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `DKIM_SELECTOR` | `mail` | DKIM selector (used in DNS record name) |
| `DKIM_KEY_DIR` | `/etc/ssl/dkim` | Directory for DKIM key storage |
| `DKIM_EXTRA_DOMAINS` | — | Comma-separated extra domains to DKIM-sign (same key) |

### Relay Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `RELAY_HOST` | — | External SMTP relay (e.g., `[smtp.gmail.com]:587`) |
| `SMTP_USERNAME` | — | Relay authentication username |
| `SMTP_PASSWORD` | — | Relay authentication password |
| `FALLBACK_RELAY_HOST` | — | Fallback relay when primary delivery fails (e.g., `[backup-smtp.example.com]:587`) |
| `FALLBACK_SMTP_USERNAME` | — | Fallback relay authentication username |
| `FALLBACK_SMTP_PASSWORD` | — | Fallback relay authentication password |

### TLS Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `LETSENCRYPT_EMAIL` | — | Enables Let's Encrypt; email for account registration |
| `LETSENCRYPT_EXTRA_DOMAINS` | — | Comma-separated extra domains for the certificate (SANs) |
| `TLS_CERT_FILE` | — | Path to an existing certificate (full chain) inside the container; with `TLS_KEY_FILE`, overrides certificate detection and issuance |
| `TLS_KEY_FILE` | — | Path to the matching private key; must be set together with `TLS_CERT_FILE` |
| `TLS_WATCH_INTERVAL` | `300` | Seconds between checks for changes to `TLS_CERT_FILE`/`TLS_KEY_FILE`; `0` checks only at startup |
| `SSL_COUNTRY` | `US` | Self-signed certificate country |
| `SSL_STATE` | `State` | Self-signed certificate state |
| `SSL_LOCALITY` | `City` | Self-signed certificate locality |
| `SSL_ORGANIZATION` | `Organization` | Self-signed certificate organization |
| `SSL_ORGANIZATIONAL_UNIT` | `IT` | Self-signed certificate OU |

### Dynamic Postfix Configuration

Any Postfix directive can be set via `POSTFIX_` prefix:
```yaml
environment:
  - POSTFIX_message_size_limit=52428800
  - POSTFIX_smtp_helo_name=mail.example.com
```

## DNS Records

For reliable mail delivery, configure these DNS records for your domain:

### PTR (Reverse DNS)

Your server's IP must have a PTR record matching `MAILNAME`. Set this at your hosting provider.

```
203.0.113.1 → mail.example.com
```

### SPF

Authorizes your server to send mail for your domain.

```
example.com.  IN  TXT  "v=spf1 mx ip4:203.0.113.1 -all"
```

### DKIM

The container prints the DKIM public key on first startup. Add it as a TXT record:

```
mail._domainkey.example.com.  IN  TXT  "v=DKIM1; k=rsa; p=<PUBLIC_KEY>"
```

Replace `mail` with your `DKIM_SELECTOR` if different.

### DMARC

Controls how receivers handle authentication failures.

```
_dmarc.example.com.  IN  TXT  "v=DMARC1; p=quarantine; rua=mailto:dmarc@example.com"
```

## Let's Encrypt

For production use, real TLS certificates improve deliverability. Set `LETSENCRYPT_EMAIL` to enable:

```yaml
environment:
  - LETSENCRYPT_EMAIL=admin@example.com
  - MAILNAME=mail.example.com
  - LETSENCRYPT_EXTRA_DOMAINS=smtp.example.com
ports:
  - "80:80"    # Required for HTTP-01 challenge
  - "25:25"
  - "587:587"
volumes:
  - letsencrypt:/etc/letsencrypt
```

The certificate is issued for `MAILNAME`, plus any `LETSENCRYPT_EXTRA_DOMAINS`. `DOMAIN` is not added automatically: it is the DKIM domain, and HTTP-01 fails when that name is behind a CDN. Every name on the certificate must have DNS that reaches this host on port 80 and must not be proxied. Certificates are issued with [acme.sh](https://github.com/acmesh-official/acme.sh) (HTTP-01, standalone). Mount the `letsencrypt` volume to persist the acme.sh account and certificates across restarts. If issuance fails, the container falls back to self-signed certificates.

## External Certificates

Certificates obtained outside the container work too, so an existing acme.sh, certbot, or commercial CA setup on the host can be reused instead of the built-in issuance. Point `TLS_CERT_FILE` and `TLS_KEY_FILE` at the mounted files:

```yaml
environment:
  - MAILNAME=mail.example.com
  - TLS_CERT_FILE=/certs/live/mail.example.com/fullchain.pem
  - TLS_KEY_FILE=/certs/live/mail.example.com/privkey.pem
volumes:
  - /srv/letsencrypt:/certs:ro
```

Mount the root of the certificate tree, not just `live/<domain>/`. In certbot's layout the files in `live/` are relative symlinks into `../../archive/`, so a mount of `live/` alone leaves the targets outside the container and the pair cannot be read. The paths above cover both `acme.sh --install-cert` output (plain files) and certbot's `live/` layout.

Port 80 is not needed and `LETSENCRYPT_EMAIL` is not used; when both are set, the external certificate wins and issuance is skipped. The files must be a matching certificate/key pair in PEM format. Anything else works as a source: a commercial certificate, a Kubernetes secret, or a directory managed by an external client.

How they are used:

- **Read at startup** — the pair is validated (parses as PEM, certificate and key belong together), its subject and expiry date are logged, and a warning is printed when it expires within 7 days.
- **Published as one file** — the key and certificate are staged in a private directory, combined into a single PEM, and published by renaming one symlink. Postfix reads it through `smtpd_tls_chain_files`; Postfix's own documentation recommends this, since with the key and certificate in separate files a process starting during a rollover can load a certificate that does not match the key. The two most recent pairs are kept. The published file is owned `root:postfix` with mode `0640`, so a bind-mounted key that is `0600` owned by a host user still works for Postfix, and key material is written under a restrictive umask, never with default permissions.
- **Validated as a chain** — every certificate in the supplied bundle is parsed, not just the first, because a valid leaf followed by a malformed intermediate passes a first-certificate-only check and then fails TLS setup. The private key must hold exactly one key, matching the leaf.
- **Watched for renewal** — every `TLS_WATCH_INTERVAL` seconds the source files are compared by content. On a change the new pair is staged, validated, published, and Postfix is reloaded, so a host-side renewal takes effect without restarting the container. The comparison starts from the pair that was published, so a renewal that lands during startup is not missed, and hashes the same bytes as the published file, so an unchanged certificate is left alone. A source that is unreadable, unparsable, or a mismatched pair is ignored and retried on the next tick, leaving the last good certificate in service.

Certificates already sitting in the standard layout `/etc/letsencrypt/live/<MAILNAME>/` are picked up without any variables: mount them there and they are used as external certificates. If the container's own acme.sh state for that name matches the active certificate and key, the built-in renewal loop keeps managing it instead, and the renewal command is re-registered on every start so a volume carried over from an earlier image still republishes renewed certificates. Stale acme.sh state that does not match the active pair is not allowed to replace it. If re-registering the renewal hook fails, startup continues with the current valid certificate but logs a warning and disables the automatic renewal loop.

If the configured files are missing, unreadable, or not a valid pair, the container logs a warning and falls back to self-signed certificates, as it does when Let's Encrypt fails. Setting these variables is a complete override: an unusable pair does not make the container reach for a certificate found elsewhere, or attempt issuance, since either would silently serve something other than what was asked for.

## Volumes

| Volume | Path | Description |
|--------|------|-------------|
| `postfix_data` | `/var/spool/postfix` | Mail queue and spool data |
| `postfix_certs` | `/etc/ssl/postfix` | Self-signed TLS certificates and published copies of external certificates |
| `dkim_keys` | `/etc/ssl/dkim` | DKIM private/public key pair |
| `letsencrypt` | `/etc/letsencrypt` | Let's Encrypt certificates and acme.sh state (optional) |

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 25 | SMTP | Standard mail delivery (direct mode) and receiving |
| 587 | Submission | Authenticated submission with STARTTLS |

## Cloud Provider Notes

Most cloud providers block outbound port 25 by default:

- **AWS**: Request removal of port 25 restriction via support ticket
- **GCP**: Blocked; use a relay or third-party SMTP service
- **Azure**: Blocked on Basic/Standard tiers; use SendGrid or relay

If port 25 is blocked, use relay mode with an external SMTP provider.

## Security

- TLS 1.2+ enforced (SSLv2, SSLv3, TLSv1, TLSv1.1 disabled)
- High-strength ciphers only
- DKIM signing for outbound mail
- Port 587 requires a SASL account from `SMTP_AUTH_USERS` over STARTTLS. Port 25 still relays for `MY_NETWORKS` without a login.
- Submission and relay passwords stay in a gitignored `.env`. Do not commit them in Compose files or the image.
- Proper sender/recipient restrictions
- Minimal base image

## Logs

All logs go to stdout:
```bash
docker logs -f postfix
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
