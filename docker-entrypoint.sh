#!/bin/bash
set -e

# Default values
MAILNAME=${MAILNAME:-"mail.example.com"}
MY_NETWORKS=${MY_NETWORKS:-"127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"}

# Function to apply postfix configurations from environment variables
apply_postfix_config() {
    # Format: POSTFIX_config_name=value
    # Example: POSTFIX_debug_peer_level=3
    for var in $(env | grep '^POSTFIX_'); do
        # Extract config name and value
        config_name=$(echo "$var" | cut -d= -f1 | sed 's/^POSTFIX_//')
        config_value=$(echo "$var" | cut -d= -f2-)
        
        echo "Setting Postfix config: $config_name = $config_value"
        postconf -e "$config_name = $config_value"
    done
}

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

echo "Creating required directories"
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

if [ ! -z "$MAILNAME" ]; then
    echo "Setting mailname to $MAILNAME"
    postconf -e "myhostname = $MAILNAME"
fi

if [ ! -z "$MY_NETWORKS" ]; then
    echo "Setting networks to $MY_NETWORKS"
    postconf -e "mynetworks = $MY_NETWORKS"
fi

if [ ! -z "$MY_DESTINATION_DOMAINS" ]; then
    echo "Setting destination domains to $MY_DESTINATION_DOMAINS"
    postconf -e "mydestination = \$myhostname, localhost, $MY_DESTINATION_DOMAINS"
fi

if [ ! -f /etc/ssl/postfix/certs/postfix.crt ] || [ ! -f /etc/ssl/postfix/private/postfix.key ]; then
    echo "Warning: TLS certificates not found in /etc/ssl/postfix/certs/postfix.crt and /etc/ssl/postfix/private/postfix.key"
    echo "Generating TLS certificates..."
    /usr/local/bin/certgen.sh
fi
 update-ca-certificates

# Create aliases if not exists
if [ ! -f /etc/aliases ]; then
    echo "Creating aliases file..."
    touch /etc/aliases
    newaliases
fi

if [ ! -z "$RELAY_HOST" ]; then
    echo "Setting relay host to $RELAY_HOST"
    postconf -e "relayhost=$RELAY_HOST"
    postconf -e "smtp_sasl_auth_enable=yes"
    postconf -e "smtp_sasl_security_options=noanonymous"
    postconf -e "smtp_sasl_password_maps=hash:/etc/postfix/sasl_passwd"
fi

# Configure SASL for SMTP if credentials are provided
if [ ! -z "$SMTP_USERNAME" ] && [ ! -z "$SMTP_PASSWORD" ]; then
    echo "Setting SMTP credentials"
    echo "${RELAY_HOST} ${SMTP_USERNAME}:${SMTP_PASSWORD}" > /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd*

    # Additional AWS SES specific settings
    postconf -e "smtp_tls_security_level = encrypt"
    postconf -e "smtp_tls_note_starttls_offer = yes"
    postconf -e "smtp_sasl_mechanism_filter = plain, login"
fi

# Configure SASL
if [ ! -f /etc/sasl2/smtpd.conf ]; then
    echo "Creating SASL configuration..."
    cat > /etc/sasl2/smtpd.conf <<EOF
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN
EOF
fi

# Apply custom Postfix configurations from environment variables
echo "Applying custom Postfix configurations..."
apply_postfix_config

echo "Checking Postfix configuration..."
postconf -n

echo "Starting Postfix..."
exec "$@"