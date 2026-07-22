#!/bin/bash
set -e

# Default values
MAILNAME=${MAILNAME:-"mail.example.com"}
DOMAIN=${DOMAIN:-"example.com"}
MY_NETWORKS=${MY_NETWORKS:-"127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"}
DKIM_SELECTOR=${DKIM_SELECTOR:-"mail"}
DKIM_KEY_DIR=${DKIM_KEY_DIR:-"/etc/ssl/dkim"}

# Function to apply postfix configurations from environment variables
apply_postfix_config() {
    # Format: POSTFIX_config_name=value
    # Example: POSTFIX_debug_peer_level=3
    for var in $(env | grep '^POSTFIX_'); do
        config_name=$(echo "$var" | cut -d= -f1 | sed 's/^POSTFIX_//')
        config_value=$(echo "$var" | cut -d= -f2-)
        echo "Setting Postfix config: $config_name = $config_value"
        postconf -e "$config_name = $config_value"
    done
}

# ============================================================
# Postfix directories and permissions
# ============================================================
echo "Creating required directories and setting permissions"
directories=(
    "/var/spool/postfix/pid"
    "/var/spool/postfix/public"
    "/var/spool/postfix/maildrop"
    "/var/spool/postfix/etc"
    "/var/spool/postfix/bounce"
    "/var/spool/postfix/corrupt"
    "/var/spool/postfix/defer"
    "/var/spool/postfix/deferred"
    "/var/spool/postfix/flush"
    "/var/spool/postfix/hold"
    "/var/spool/postfix/incoming"
    "/var/spool/postfix/active"
    "/var/spool/postfix/trace"
)

if [ -f /var/spool/postfix/pid/master.pid ]; then
    echo "Cleaning up stale master PID"
    rm -f /var/spool/postfix/pid/master.pid
fi

for dir in "${directories[@]}"; do
    mkdir -p "$dir"
done

echo "Adding symlinks for DNS resolution"
ln -sf /etc/resolv.conf /var/spool/postfix/etc/resolv.conf

echo "Setting correct permissions"
chown -R postfix:root /var/lib/postfix
chmod 700 /var/lib/postfix
chown root:root /var/spool/postfix
chown root:root /var/spool/postfix/etc/resolv.conf
chown root:root /var/spool/postfix/pid
chown root:root /var/spool/postfix/etc
chown postfix:postfix /var/spool/postfix/bounce
chown postfix:root /var/spool/postfix/{corrupt,defer,deferred,flush,hold,incoming,active,trace}
chown postfix:postdrop /var/spool/postfix/{public,maildrop}
chgrp postdrop /usr/sbin/postqueue
chgrp postdrop /usr/sbin/postdrop
chmod g+s /usr/sbin/postqueue
chmod g+s /usr/sbin/postdrop

if [ ! -f /etc/postfix/transport ]; then
    echo "Setting up transport map"
    touch /etc/postfix/transport
    postmap /etc/postfix/transport
fi
chown root:root /etc/postfix/transport*

# ============================================================
# Postfix basic configuration
# ============================================================
if [ -n "$MAILNAME" ]; then
    echo "Setting mailname to $MAILNAME"
    postconf -e "myhostname = $MAILNAME"
fi

if [ -n "$MY_NETWORKS" ]; then
    echo "Setting networks to $MY_NETWORKS"
    postconf -e "mynetworks = $MY_NETWORKS"
fi

if [ -n "$MY_DESTINATION_DOMAINS" ]; then
    echo "Setting destination domains to $MY_DESTINATION_DOMAINS"
    postconf -e "mydestination = \$myhostname, localhost, $MY_DESTINATION_DOMAINS"
fi

# ============================================================
# TLS certificates — Let's Encrypt or self-signed
# ============================================================
if [ -n "$LETSENCRYPT_EMAIL" ] && [ -n "$DOMAIN" ]; then
    ACME_SH=/opt/acme.sh/acme.sh
    # State (account + issued certs) lives on the letsencrypt volume so it
    # survives container recreation and enables renewal without re-registering.
    ACME_CONFIG=/etc/letsencrypt/acme.sh
    LE_DIR="/etc/letsencrypt/live/${DOMAIN}"
    LE_CERT="${LE_DIR}/fullchain.pem"
    LE_KEY="${LE_DIR}/privkey.pem"
    mkdir -p "$LE_DIR" "$ACME_CONFIG"

    if [ -f "$LE_CERT" ] && [ -f "$LE_KEY" ]; then
        echo "Using existing Let's Encrypt certificates for ${DOMAIN}"
    else
        echo "Requesting Let's Encrypt certificate for ${DOMAIN} via acme.sh..."
        # Build acme.sh domain arguments
        ACME_DOMAINS="-d ${DOMAIN}"
        if [ -n "$LETSENCRYPT_EXTRA_DOMAINS" ]; then
            for extra_domain in $(echo "$LETSENCRYPT_EXTRA_DOMAINS" | tr ',' ' '); do
                ACME_DOMAINS="${ACME_DOMAINS} -d ${extra_domain}"
            done
        fi
        if "$ACME_SH" --issue --standalone \
                --config-home "$ACME_CONFIG" \
                --server letsencrypt \
                --accountemail "$LETSENCRYPT_EMAIL" \
                $ACME_DOMAINS && \
           "$ACME_SH" --install-cert -d "$DOMAIN" \
                --config-home "$ACME_CONFIG" \
                --key-file "$LE_KEY" \
                --fullchain-file "$LE_CERT"; then
            echo "Let's Encrypt certificate obtained successfully"
        else
            echo "Warning: Let's Encrypt failed, falling back to self-signed certificates"
            LETSENCRYPT_EMAIL=""
        fi
    fi

    if [ -n "$LETSENCRYPT_EMAIL" ] && [ -f "$LE_CERT" ] && [ -f "$LE_KEY" ]; then
        postconf -e "smtpd_tls_cert_file = $LE_CERT"
        postconf -e "smtpd_tls_key_file = $LE_KEY"
    fi
fi

# Fall back to self-signed if no Let's Encrypt
if [ -z "$LETSENCRYPT_EMAIL" ]; then
    if [ ! -f /etc/ssl/postfix/certs/postfix.crt ] || [ ! -f /etc/ssl/postfix/private/postfix.key ]; then
        echo "Warning: TLS certificates not found"
        echo "Generating self-signed TLS certificates..."
        /usr/local/bin/certgen.sh
    fi
fi

update-ca-certificates

# Create aliases if not exists
if [ ! -f /etc/aliases ]; then
    echo "Creating aliases file..."
    touch /etc/aliases
    newaliases
fi

# ============================================================
# Mode selection: Direct delivery vs Relay
# ============================================================
if [ -n "$RELAY_HOST" ]; then
    echo "=== RELAY MODE: forwarding mail through $RELAY_HOST ==="
    postconf -e "relayhost = $RELAY_HOST"
    postconf -e "smtp_tls_security_level = encrypt"
    postconf -e "smtp_tls_note_starttls_offer = yes"

    if [ -n "$SMTP_USERNAME" ] && [ -n "$SMTP_PASSWORD" ]; then
        echo "Configuring SMTP relay credentials"
        echo "${RELAY_HOST} ${SMTP_USERNAME}:${SMTP_PASSWORD}" > /etc/postfix/sasl_passwd
        postmap /etc/postfix/sasl_passwd
        chmod 600 /etc/postfix/sasl_passwd*
        postconf -e "smtp_sasl_auth_enable = yes"
        postconf -e "smtp_sasl_security_options = noanonymous"
        postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
        postconf -e "smtp_sasl_mechanism_filter = plain, login"
    fi
else
    echo "=== DIRECT MODE: delivering mail directly to recipient MX servers ==="
    postconf -e "smtp_tls_security_level = may"
    postconf -e "disable_dns_lookups = no"
fi

# Fallback relay — used when primary delivery (direct or relay) fails
if [ -n "$FALLBACK_RELAY_HOST" ]; then
    echo "Configuring fallback relay: $FALLBACK_RELAY_HOST"
    postconf -e "smtp_fallback_relay = $FALLBACK_RELAY_HOST"

    if [ -n "$FALLBACK_SMTP_USERNAME" ] && [ -n "$FALLBACK_SMTP_PASSWORD" ]; then
        echo "Configuring fallback relay credentials"
        # Ensure sasl_passwd exists (may not if primary relay has no credentials)
        touch /etc/postfix/sasl_passwd
        echo "${FALLBACK_RELAY_HOST} ${FALLBACK_SMTP_USERNAME}:${FALLBACK_SMTP_PASSWORD}" >> /etc/postfix/sasl_passwd
        postmap /etc/postfix/sasl_passwd
        chmod 600 /etc/postfix/sasl_passwd*
        # Enable SASL if not already enabled (needed for direct mode with fallback)
        postconf -e "smtp_sasl_auth_enable = yes"
        postconf -e "smtp_sasl_security_options = noanonymous"
        postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    fi
fi

# Configure SASL for inbound authentication
if [ ! -f /etc/sasl2/smtpd.conf ]; then
    echo "Creating SASL configuration..."
    cat > /etc/sasl2/smtpd.conf <<EOF
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN
EOF
fi

# Provision SASL users for authenticated submission (port 587).
# Format: SMTP_AUTH_USERS=user1:pass1,user2:pass2
# Clients authenticate with the bare username and the realm $MAILNAME
# (matches smtpd_sasl_local_domain = $myhostname in main.cf).
if [ -n "$SMTP_AUTH_USERS" ]; then
    echo "Provisioning SASL submission users..."
    IFS=',' read -ra _auth_pairs <<< "$SMTP_AUTH_USERS"
    for pair in "${_auth_pairs[@]}"; do
        case "$pair" in
            *:*) ;;
            *) echo "Warning: skipping malformed SMTP_AUTH_USERS entry (expected user:pass)"; continue ;;
        esac
        auth_user="${pair%%:*}"
        auth_pass="${pair#*:}"
        if [ -z "$auth_user" ]; then
            echo "Warning: skipping SMTP_AUTH_USERS entry with empty username"
            continue
        fi
        echo "Adding SASL user: $auth_user"
        echo "$auth_pass" | saslpasswd2 -p -c -u "$MAILNAME" "$auth_user"
    done
    # smtpd runs as the postfix user and must be able to read the sasldb
    if [ -f /etc/sasldb2 ]; then
        chown root:postfix /etc/sasldb2
        chmod 640 /etc/sasldb2
    fi
fi

# Apply custom Postfix configurations from environment variables
echo "Applying custom Postfix configurations..."
apply_postfix_config

# ============================================================
# OpenDKIM setup
# ============================================================
echo "Configuring OpenDKIM for domain: ${DOMAIN} (selector: ${DKIM_SELECTOR})"

mkdir -p "${DKIM_KEY_DIR}" /var/run/opendkim /etc/opendkim

# Substitute placeholders in OpenDKIM config files
for conf_file in /etc/opendkim.conf /etc/opendkim/signing.table /etc/opendkim/key.table /etc/opendkim/trusted.hosts; do
    if [ -f "$conf_file" ]; then
        sed -i \
            -e "s|__DKIM_SELECTOR__|${DKIM_SELECTOR}|g" \
            -e "s|__DOMAIN__|${DOMAIN}|g" \
            "$conf_file"
    fi
done

# Add extra domains to DKIM signing/key tables and trusted hosts
# DKIM_EXTRA_DOMAINS: comma-separated list of additional domains to sign
if [ -n "$DKIM_EXTRA_DOMAINS" ]; then
    for extra_domain in $(echo "$DKIM_EXTRA_DOMAINS" | tr ',' ' '); do
        echo "Adding DKIM signing for extra domain: ${extra_domain}"
        signing_line="*@${extra_domain} ${DKIM_SELECTOR}._domainkey.${extra_domain}"
        key_line="${DKIM_SELECTOR}._domainkey.${extra_domain} ${extra_domain}:${DKIM_SELECTOR}:/etc/ssl/dkim/dkim.key"
        # Guard appends so restarts don't accumulate duplicate lines
        grep -qxF "$signing_line" /etc/opendkim/signing.table || echo "$signing_line" >> /etc/opendkim/signing.table
        grep -qxF "$key_line" /etc/opendkim/key.table || echo "$key_line" >> /etc/opendkim/key.table
        grep -qxF "${extra_domain}" /etc/opendkim/trusted.hosts || echo "${extra_domain}" >> /etc/opendkim/trusted.hosts
        grep -qxF "*.${extra_domain}" /etc/opendkim/trusted.hosts || echo "*.${extra_domain}" >> /etc/opendkim/trusted.hosts
    done
fi

# Expand MY_NETWORKS into trusted.hosts (one entry per line)
if [ -f /etc/opendkim/trusted.hosts ]; then
    sed -i '/__MY_NETWORKS_EXPANDED__/d' /etc/opendkim/trusted.hosts
    for network in $(echo "$MY_NETWORKS" | tr ',' ' '); do
        # Guard appends so restarts don't accumulate duplicate lines
        grep -qxF "$network" /etc/opendkim/trusted.hosts || echo "$network" >> /etc/opendkim/trusted.hosts
    done
fi

# Generate DKIM key if not present
if [ ! -f "${DKIM_KEY_DIR}/dkim.key" ]; then
    echo "Generating DKIM private key (2048-bit RSA)..."
    openssl genrsa -out "${DKIM_KEY_DIR}/dkim.key" 2048

    echo "Extracting DKIM public key..."
    openssl rsa -in "${DKIM_KEY_DIR}/dkim.key" -pubout -outform der 2>/dev/null | openssl base64 -A > "${DKIM_KEY_DIR}/dkim.pub"

    DKIM_PUBKEY=$(cat "${DKIM_KEY_DIR}/dkim.pub")
    echo ""
    echo "============================================================"
    echo "DKIM PUBLIC KEY — Add these DNS TXT records:"
    echo ""
    echo "  ${DKIM_SELECTOR}._domainkey.${DOMAIN} IN TXT \"v=DKIM1; k=rsa; p=${DKIM_PUBKEY}\""
    if [ -n "$DKIM_EXTRA_DOMAINS" ]; then
        for extra_domain in $(echo "$DKIM_EXTRA_DOMAINS" | tr ',' ' '); do
            echo "  ${DKIM_SELECTOR}._domainkey.${extra_domain} IN TXT \"v=DKIM1; k=rsa; p=${DKIM_PUBKEY}\""
        done
    fi
    echo ""
    echo "============================================================"
    echo ""
fi

chown -R opendkim:opendkim "${DKIM_KEY_DIR}" /var/run/opendkim
chmod 600 "${DKIM_KEY_DIR}/dkim.key"

# ============================================================
# Start services
# ============================================================
echo "Checking Postfix configuration..."
postconf -n

echo "Starting OpenDKIM..."
opendkim -x /etc/opendkim.conf -f -l &
OPENDKIM_PID=$!

# Signal handling: clean up both processes on shutdown
cleanup() {
    echo "Shutting down..."
    kill "$OPENDKIM_PID" 2>/dev/null
    wait "$OPENDKIM_PID" 2>/dev/null
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "Starting Postfix..."
exec "$@"
