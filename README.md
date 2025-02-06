# Postfix Docker Image

[![Docker Pulls](https://img.shields.io/docker/pulls/01it/postfix.svg)](https://hub.docker.com/r/01it/postfix)
[![Docker Stars](https://img.shields.io/docker/stars/01it/postfix.svg)](https://hub.docker.com/r/01it/postfix)
[![GitHub release](https://img.shields.io/github/release/1it/docker-postfix.svg)](https://github.com/1it/docker-postfix/releases)

Secure, minimal Postfix mail server with built-in TLS support and relay capabilities.

## Features

- Minimal base image
- Built-in TLS support
- SMTP relay support
- Automated TLS certificate generation
- Configurable via environment variables
- Proper permission handling
- Volume support for persistent data

## Quick Start

Using pre-built image:

```bash
docker run -d --name postfix -p 25:25 -p 587:587 -v postfix_data:/var/spool/postfix 01it/postfix:latest
```

From source:

1. Clone the repository
2. Build the image (optionally with custom configuration)
3. Run the container

Example docker-compose.yml:
```bash 
docker compose up -d
```

## Configuration

The container can be configured via environment variables:

### TLS Configuration:

- `DOMAIN`: The domain name for the mail server
- `SSL_COUNTRY`: The country for the TLS certificate
- `SSL_STATE`: The state for the TLS certificate
- `SSL_LOCALITY`: The locality for the TLS certificate
- `SSL_ORGANIZATION`: The organization for the TLS certificate
- `SSL_ORGANIZATIONAL_UNIT`: The organizational unit for the TLS certificate

### SMTP Relay Configuration:

- `RELAY_HOST`: The relay host for the mail server
- `SMTP_USERNAME`: The relay user for the mail server
- `SMTP_PASSWORD`: The relay password for the mail server

### Postfix Custom Configuration via environment variables:

- `MAILNAME`: The mailname for the mail server
- `MY_NETWORKS`: The networks access list for the inbound mail server
- `MY_DESTINATION_DOMAINS`: The destination domains for the mail server

- `POSTFIX_any_postfix_config_directive`: The custom Postfix configuration directive, where `POSTFIX_` is the prefix of the directive, any configuration directive can be used.
   For example: 
   - `POSTFIX_smtpd_client_restrictions=permit_mynetworks,permit`
   - `POSTFIX_smtpd_relay_restrictions=permit_mynetworks,reject_unauth_destination,permit`
   - `POSTFIX_mynetworks=127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16`


## Volumes

- `postfix_data`: The volume for the postfix data
- `postfix_certs`: The volume for the postfix certificates

## Security

- TLS enabled by default
- Proper file permissions
- Minimal base image to reduce attack surface
- No default passwords or configurations

The container will automatically generate a TLS certificate if it doesn't exist. The certificate will be generated using the `certgen.sh` script.

## Logs

The container will log to the console.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

