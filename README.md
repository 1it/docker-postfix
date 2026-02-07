# Postfix Docker Image

[![Docker Pulls](https://img.shields.io/docker/pulls/01it/postfix.svg)](https://hub.docker.com/r/01it/postfix)
[![Docker Stars](https://img.shields.io/docker/stars/01it/postfix.svg)](https://hub.docker.com/r/01it/postfix)
[![GitHub release](https://img.shields.io/github/release/1it/docker-postfix.svg)](https://github.com/1it/docker-postfix/releases)

Lightweight Postfix mail relay with built-in DKIM signing, TLS support, and flexible delivery modes.

## Features

- **Direct delivery** — send mail directly to recipient MX servers (default)
- **Relay mode** — forward mail through an external SMTP provider (AWS SES, Gmail, etc.)
- **DKIM signing** — embedded OpenDKIM with automatic key generation
- **TLS** — auto-generated self-signed certs or Let's Encrypt
- **Configurable** — all settings via environment variables
- **Minimal** — multi-stage Debian Bookworm build
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

```yaml
environment:
  - RELAY_HOST=[smtp.example.com]:587
  - SMTP_USERNAME=your-username
  - SMTP_PASSWORD=your-password
```

## Configuration

### Core Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `DOMAIN` | `example.com` | Domain for DKIM signing and certificate generation |
| `MAILNAME` | `mail.example.com` | Postfix hostname (`myhostname`) |
| `MY_NETWORKS` | `127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16` | Trusted networks allowed to relay |
| `MY_DESTINATION_DOMAINS` | — | Additional local destination domains |

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
  - DOMAIN=example.com
ports:
  - "80:80"    # Required for HTTP-01 challenge
  - "25:25"
  - "587:587"
volumes:
  - letsencrypt:/etc/letsencrypt
```

Port 80 must be accessible from the internet during certificate issuance. If certbot fails, the container falls back to self-signed certificates.

## Volumes

| Volume | Path | Description |
|--------|------|-------------|
| `postfix_data` | `/var/spool/postfix` | Mail queue and spool data |
| `postfix_certs` | `/etc/ssl/postfix` | Self-signed TLS certificates |
| `dkim_keys` | `/etc/ssl/dkim` | DKIM private/public key pair |
| `letsencrypt` | `/etc/letsencrypt` | Let's Encrypt certificates (optional) |

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 25 | SMTP | Standard mail delivery (direct mode) and receiving |
| 465 | SMTPS | Implicit TLS submission |
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
- SASL authentication on submission port
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
