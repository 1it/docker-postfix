#!/bin/bash
set -e

# Default values
MAILNAME=${MAILNAME:-"mail.example.com"}
DOMAIN=${DOMAIN:-"example.com"}
MY_NETWORKS=${MY_NETWORKS:-"127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"}
DKIM_SELECTOR=${DKIM_SELECTOR:-"mail"}
DKIM_KEY_DIR=${DKIM_KEY_DIR:-"/etc/ssl/dkim"}

# Export so child processes (certgen.sh) inherit the resolved values even
# when the caller did not pass them via -e.
export MAILNAME DOMAIN

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
# TLS certificates — external, Let's Encrypt, or self-signed
# ============================================================
# Resolution order:
#   1. TLS_CERT_FILE + TLS_KEY_FILE — a pair issued and renewed outside the
#      container (host acme.sh, certbot, a commercial CA, a mounted secret).
#      The pair is published inside the image and Postfix is reloaded whenever
#      the source files change, so external renewals need no container restart.
#   2. /etc/letsencrypt/live/<MAILNAME>/ — the standard acme.sh layout, e.g.
#      pre-populated by an acme.sh running on the host.
#   3. LETSENCRYPT_EMAIL — issue and renew in-container with acme.sh.
#   4. Self-signed certificates.
#
# Every pair, however it was obtained, is published the same way: staged,
# validated and installed as one combined PEM behind a single symlink rename.
# See /usr/local/bin/tls-publish.sh.
. /usr/local/bin/tls-publish.sh

ACME_SH=/opt/acme.sh/acme.sh
# State (account + issued certs) lives on the letsencrypt volume so it
# survives container recreation and enables renewal without re-registering.
ACME_CONFIG=/etc/letsencrypt/acme.sh
# HTTP-01 standalone can only succeed for names that resolve to this host.
# DOMAIN is the DKIM signing domain and is often a site behind a CDN, so the
# certificate is issued for MAILNAME (the name SMTP clients connect to).
LE_PRIMARY="${MAILNAME:-$DOMAIN}"
LE_DIR="/etc/letsencrypt/live/${LE_PRIMARY}"
LE_CERT="${LE_DIR}/fullchain.pem"
LE_KEY="${LE_DIR}/privkey.pem"

# How often an external pair is checked for changes, in seconds. 0 disables the
# check and applies the pair only at startup.
TLS_WATCH_INTERVAL=${TLS_WATCH_INTERVAL:-300}

TLS_MODE=""             # external | letsencrypt
TLS_SOURCE_CERT=""      # certificate the pair is published from
TLS_SOURCE_KEY=""       # private key the pair is published from
TLS_WATCH=0             # watch the external pair for changes
TLS_EXPLICIT=0          # TLS_CERT_FILE/TLS_KEY_FILE were supplied by the operator

# True when this container's own acme.sh issued the certificate for LE_PRIMARY
# and can therefore renew it. acme.sh keeps per-domain state under
# <config-home>/<domain>/ for RSA keys and <config-home>/<domain>_ecc/ for EC
# ones, and ec-256 is its default, so both layouts have to be recognized.
acme_manages_domain() {
    [ -f "${ACME_CONFIG}/${LE_PRIMARY}/${LE_PRIMARY}.cer" ] ||
        [ -f "${ACME_CONFIG}/${LE_PRIMARY}_ecc/${LE_PRIMARY}.cer" ]
}

# --- 1. Explicit external certificate paths ---------------------------------
if [ -n "$TLS_CERT_FILE" ] || [ -n "$TLS_KEY_FILE" ]; then
    if [ -z "$TLS_CERT_FILE" ] || [ -z "$TLS_KEY_FILE" ]; then
        echo "Warning: TLS_CERT_FILE and TLS_KEY_FILE must be set together, ignoring them"
    else
        TLS_EXPLICIT=1
        echo "TLS_CERT_FILE/TLS_KEY_FILE set, using externally managed certificates"
        if tls_publish_pair "$TLS_CERT_FILE" "$TLS_KEY_FILE"; then
            TLS_MODE=external
            TLS_SOURCE_CERT="$TLS_CERT_FILE"
            TLS_SOURCE_KEY="$TLS_KEY_FILE"
            if [ -n "$LETSENCRYPT_EMAIL" ]; then
                echo "LETSENCRYPT_EMAIL is ignored while an external certificate is configured"
            fi
        else
            # An explicit pair that cannot be published is a configuration
            # error, not a reason to issue over HTTP-01: fall back, and remember
            # that the operator asked for external certificates so that the
            # issuance branch below stays skipped.
            echo "Warning: unusable external certificate pair, falling back"
        fi
    fi
fi

# --- 2. Certificates already present in the standard acme.sh layout ---------
# Skipped when explicit certificate paths were given: those select the
# certificate, so a stale file under /etc/letsencrypt must not quietly become
# the pair in service, whether it is acme.sh-managed or externally supplied.
if [ -z "$TLS_MODE" ] && [ "$TLS_EXPLICIT" = "0" ] && [ -n "$LE_PRIMARY" ] && [ -e "$LE_CERT" ] && [ -e "$LE_KEY" ]; then
    if acme_manages_domain; then
        # Issued by this container earlier; keep the acme.sh renewal path and
        # re-register the install paths and the publisher as its renewal
        # command. Volumes created by an earlier image still have "postfix
        # reload" stored, and since this branch does not issue, nothing would
        # ever replace it: a renewal would update these source files while
        # Postfix kept reading the combined PEM, which then expires. Both the
        # RSA and EC state layouts are registered.
        echo "Using existing Let's Encrypt certificates for ${LE_PRIMARY}"
        TLS_ECC_OPT=""
        if [ ! -d "${ACME_CONFIG}/${LE_PRIMARY}" ] && [ -d "${ACME_CONFIG}/${LE_PRIMARY}_ecc" ]; then
            TLS_ECC_OPT="--ecc"
        fi
        # --install-cert rewrites the target files from acme.sh's own state, so
        # an incomplete or unreadable state directory can truncate a working
        # certificate to zero bytes. Keep a copy and restore it if the
        # registration does not leave a usable pair behind.
        tls_backup_dir=$(mktemp -d)
        cat "$LE_CERT" > "${tls_backup_dir}/fullchain.pem" 2>/dev/null
        cat "$LE_KEY" > "${tls_backup_dir}/privkey.pem" 2>/dev/null
        # shellcheck disable=SC2086 # TLS_ECC_OPT is intentionally empty or --ecc
        if "$ACME_SH" --install-cert -d "$LE_PRIMARY" $TLS_ECC_OPT \
                --config-home "$ACME_CONFIG" \
                --key-file "$LE_KEY" \
                --fullchain-file "$LE_CERT" \
                --reloadcmd "/usr/local/bin/tls-publish.sh $LE_CERT $LE_KEY" >/dev/null 2>&1; then
            echo "Registered the renewal command for ${LE_PRIMARY}"
        else
            # Not fatal on its own: the certificate in use is unaffected, only
            # renewal automation. But say so explicitly, since it means the loop
            # below cannot publish renewed pairs.
            echo "Warning: could not register the renewal command for ${LE_PRIMARY}, renewals may not be applied"
        fi
        # Whatever happened above, never continue with a pair acme.sh damaged.
        if ! openssl x509 -in "$LE_CERT" -noout >/dev/null 2>&1 || ! openssl pkey -in "$LE_KEY" -noout >/dev/null 2>&1; then
            echo "Warning: re-registering damaged ${LE_DIR}, restoring the previous files"
            cat "${tls_backup_dir}/fullchain.pem" > "$LE_CERT" 2>/dev/null
            cat "${tls_backup_dir}/privkey.pem" > "$LE_KEY" 2>/dev/null
        fi
        rm -rf "$tls_backup_dir"
        TLS_MODE=letsencrypt
        TLS_SOURCE_CERT="$LE_CERT"
        TLS_SOURCE_KEY="$LE_KEY"
    else
        # No acme.sh state for this name: the files were placed there by
        # something outside the container, so treat them as externally renewed.
        echo "Found certificates at ${LE_DIR} without local acme.sh state"
        if tls_publish_pair "$LE_CERT" "$LE_KEY"; then
            TLS_MODE=external
            TLS_SOURCE_CERT="$LE_CERT"
            TLS_SOURCE_KEY="$LE_KEY"
            echo "Using externally managed certificates from ${LE_DIR}"
            if [ -n "$LETSENCRYPT_EMAIL" ]; then
                echo "LETSENCRYPT_EMAIL is ignored while an external certificate is configured"
            fi
        else
            echo "Warning: unusable certificate pair in ${LE_DIR}, falling back"
        fi
    fi
fi

# --- 3. Issue with Let's Encrypt (acme.sh, HTTP-01 standalone) --------------
# Skipped when explicit certificate paths were given: those override issuance
# whether or not the pair turned out to be usable.
if [ -z "$TLS_MODE" ] && [ "$TLS_EXPLICIT" = "0" ] && [ -n "$LETSENCRYPT_EMAIL" ] && [ -n "$LE_PRIMARY" ]; then
    mkdir -p "$LE_DIR" "$ACME_CONFIG"

    # Build acme.sh domain arguments. Skip DOMAIN unless it is MAILNAME
    # or explicitly listed in LETSENCRYPT_EXTRA_DOMAINS.
    ACME_DOMAINS="-d ${LE_PRIMARY}"
    if [ -n "$LETSENCRYPT_EXTRA_DOMAINS" ]; then
        for extra_domain in $(echo "$LETSENCRYPT_EXTRA_DOMAINS" | tr ',' ' '); do
            if [ "$extra_domain" = "$LE_PRIMARY" ]; then
                continue
            fi
            ACME_DOMAINS="${ACME_DOMAINS} -d ${extra_domain}"
        done
    fi
    echo "Requesting Let's Encrypt certificate via HTTP-01 for: ${ACME_DOMAINS}"
    echo "Each name must resolve to this host on port 80 and must not be proxied by a CDN."
    # acme.sh runs --reloadcmd after installing and fails the install when it
    # exits non-zero, so the command publishes the renewed pair instead of a
    # bare "postfix reload": it must also succeed during startup, before the
    # Postfix daemon runs.
    if "$ACME_SH" --issue --standalone \
            --config-home "$ACME_CONFIG" \
            --server letsencrypt \
            --accountemail "$LETSENCRYPT_EMAIL" \
            $ACME_DOMAINS && \
       "$ACME_SH" --install-cert -d "$LE_PRIMARY" \
            --config-home "$ACME_CONFIG" \
            --key-file "$LE_KEY" \
            --fullchain-file "$LE_CERT" \
            --reloadcmd "/usr/local/bin/tls-publish.sh $LE_CERT $LE_KEY"; then
        echo "Let's Encrypt certificate obtained successfully"
        TLS_MODE=letsencrypt
        TLS_SOURCE_CERT="$LE_CERT"
        TLS_SOURCE_KEY="$LE_KEY"
    else
        echo "Warning: Let's Encrypt failed, falling back to self-signed certificates"
        LETSENCRYPT_EMAIL=""
    fi
fi

# --- Apply the published certificate to Postfix -----------------------------
if [ -n "$TLS_MODE" ] && [ "$TLS_MODE" = "letsencrypt" ]; then
    # Always publish an acme.sh-managed pair, even when a combined PEM already
    # exists on the persistent postfix_certs volume: it may belong to a previous
    # source, another MAILNAME, or an older version of this certificate, and
    # Postfix would serve it until some later renewal replaced it. External
    # pairs are already published in step 1 or 2.
    if ! tls_publish_pair "$TLS_SOURCE_CERT" "$TLS_SOURCE_KEY"; then
        echo "Warning: could not publish the certificate, falling back to self-signed certificates"
        TLS_MODE=""
    fi
elif [ -n "$TLS_MODE" ] && [ ! -r "$TLS_CHAIN_FILE" ]; then
    if ! tls_publish_pair "$TLS_SOURCE_CERT" "$TLS_SOURCE_KEY"; then
        echo "Warning: could not publish the certificate, falling back to self-signed certificates"
        TLS_MODE=""
    fi
fi

if [ -n "$TLS_MODE" ]; then
    tls_apply_postfix_conf
    echo "Postfix reads the certificate from ${TLS_CHAIN_FILE}"
    if [ "$TLS_MODE" = "external" ]; then
        # Nothing renews an external pair from here, so watch it and reload on change.
        if [ "$TLS_WATCH_INTERVAL" -gt 0 ] 2>/dev/null; then
            TLS_WATCH=1
            echo "Watching ${TLS_SOURCE_CERT} every ${TLS_WATCH_INTERVAL}s for renewals"
        else
            echo "TLS_WATCH_INTERVAL is not a positive number, watching is disabled"
        fi
    fi
fi

# --- 4. Self-signed fallback ------------------------------------------------
if [ -z "$TLS_MODE" ]; then
    if [ ! -f /etc/ssl/postfix/certs/postfix.crt ] || [ ! -f /etc/ssl/postfix/private/postfix.key ]; then
        echo "Warning: TLS certificates not found"
        echo "Generating self-signed TLS certificates..."
        /usr/local/bin/certgen.sh
    fi
    # Point Postfix back at them. An earlier run on the same container may have
    # set smtpd_tls_chain_files, which Postfix prefers over these parameters, so
    # generating the files is not enough on its own.
    tls_apply_self_signed_conf
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

BG_PIDS=()

# Let's Encrypt auto-renewal: acme.sh --cron renews certs nearing expiry
# and runs the stored --reloadcmd (tls-publish.sh) on success.
if [ "$TLS_MODE" = "letsencrypt" ] && [ -n "$LE_PRIMARY" ] && [ -f "$LE_CERT" ]; then
    echo "Starting Let's Encrypt renewal loop..."
    ( while true; do
        sleep 12h
        /opt/acme.sh/acme.sh --cron --config-home /etc/letsencrypt/acme.sh
      done ) &
    BG_PIDS+=("$!")
fi

# External certificate watch: the pair is issued and renewed outside the
# container (host acme.sh, certbot, a mounted secret). Copy the new pair in and
# reload Postfix so clients pick it up without a container restart. A rejected
# or unreadable pair is ignored until the next tick, keeping the last good one
# in service.
if [ "$TLS_WATCH" = "1" ]; then
    echo "Starting external certificate watcher..."
    (
      # Baseline is the pair Postfix actually serves, not the source: a renewal
      # that lands between publishing and this line would otherwise be recorded
      # as already applied while the previous pair is still live.
      TLS_CERT_FINGERPRINT=$(tls_installed_fingerprint) || TLS_CERT_FINGERPRINT=""
      while true; do
        sleep "$TLS_WATCH_INTERVAL"
        current=$(tls_pair_fingerprint "$TLS_SOURCE_CERT" "$TLS_SOURCE_KEY") || current=""
        # Empty fingerprint: files are mid-rotation or gone, retry next tick.
        [ -n "$current" ] || continue
        [ "$current" != "$TLS_CERT_FINGERPRINT" ] || continue
        echo "External certificate changed, validating..."
        if tls_publish_pair "$TLS_SOURCE_CERT" "$TLS_SOURCE_KEY"; then
            tls_apply_postfix_conf
            if postfix reload; then
                echo "Postfix reloaded with the renewed certificate"
                # Fingerprint what is now live. If the source changed again while
                # it was being copied, this differs from $current and the next
                # tick publishes the newer pair.
                TLS_CERT_FINGERPRINT=$(tls_installed_fingerprint) || TLS_CERT_FINGERPRINT=""
            else
                # Leave the fingerprint unchanged so the next tick retries.
                echo "Warning: postfix reload failed, retrying on the next check"
            fi
        else
            echo "Warning: new external certificate rejected, keeping the previous one"
        fi
      done
    ) &
    BG_PIDS+=("$!")
fi

# Signal handling: clean up background processes on shutdown
cleanup() {
    echo "Shutting down..."
    kill "$OPENDKIM_PID" 2>/dev/null
    for pid in "${BG_PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
    wait "$OPENDKIM_PID" 2>/dev/null
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "Starting Postfix..."
exec "$@"
