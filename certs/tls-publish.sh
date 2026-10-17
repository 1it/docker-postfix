#!/bin/bash
# Stage, validate and publish a TLS certificate/key pair for Postfix.
#
# Postfix documents that a key and its certificate kept in separate files can
# be read inconsistently during a rollover (postconf(5), smtpd_tls_chain_files:
# "there is a chance that during key rollover a Postfix process might load a
# private key and certificate from separate files that don't match"). The pair
# is therefore published as one combined PEM, key first, followed by the
# certificate chain, and Postfix reads it through smtpd_tls_chain_files.
#
# The combined file also goes through a single symlink rename, so the pair
# becomes live in one step and a failed install leaves the previous pair in
# place. The two most recent pairs are kept on disk.
#
# Sourced by docker-entrypoint.sh. It also runs as a command:
#
#   tls-publish.sh <cert-file> <key-file>
#
# publishes the pair, applies the Postfix settings and reloads Postfix when it
# is already running. That is the command acme.sh runs through --reloadcmd, so
# an in-container renewal publishes exactly like an external one.

TLS_STATE_DIR=${TLS_STATE_DIR:-/etc/ssl/postfix/tls}
TLS_CHAIN_FILE="${TLS_STATE_DIR}/live/tls.pem"
# Number of published pairs to keep, including the live one.
TLS_GENERATIONS=${TLS_GENERATIONS:-2}
case "$TLS_GENERATIONS" in
    ''|*[!0-9]*) TLS_GENERATIONS=2 ;;
esac
[ "$TLS_GENERATIONS" -ge 1 ] || TLS_GENERATIONS=1

# Print a short description of the certificate and fail when the pair cannot be
# served. Called on the staged files, so what is validated is what is published.
tls_validate_pair() {
    local cert="$1" key="$2" cert_hash key_hash subject not_after chain_split count block

    if ! openssl x509 -in "$cert" -noout >/dev/null 2>&1; then
        echo "  cannot parse the leaf certificate: $cert"
        return 1
    fi
    if ! openssl pkey -in "$key" -noout >/dev/null 2>&1; then
        echo "  cannot parse the private key: $key"
        return 1
    fi

    # Postfix loads at most one key per algorithm from smtpd_tls_chain_files, so
    # a bundle holding several keys is refused instead of silently mis-paired.
    count=$(grep -c -E '^-----BEGIN ((RSA|EC|DSA|ENCRYPTED) )?PRIVATE KEY-----$' "$key" 2>/dev/null || true)
    if [ "${count:-0}" -lt 1 ]; then
        echo "  no PEM private key found in $key"
        return 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "  $key holds $count private keys, expected exactly one"
        return 1
    fi

    # openssl x509 only reads the first certificate of a bundle, so every
    # certificate in the chain is checked separately: a valid leaf followed by
    # a malformed intermediate would otherwise pass and break TLS setup.
    mkdir -p "$TLS_STATE_DIR" || return 1
    chain_split=$(mktemp -d "${TLS_STATE_DIR}/.chain-check.XXXXXX") || return 1
    if ! awk -v dir="$chain_split" '
        /-----BEGIN CERTIFICATE-----/ { n++; file = sprintf("%s/%04d.pem", dir, n) }
        n > 0 { print > file }
    ' "$cert" 2>/dev/null; then
        echo "  could not split the certificate chain: $cert"
        rm -rf "$chain_split"
        return 1
    fi
    count=0
    for block in "$chain_split"/*.pem; do
        [ -f "$block" ] || continue
        count=$((count + 1))
    done
    if [ "${count:-0}" -lt 1 ]; then
        echo "  no PEM certificate found in $cert"
        rm -rf "$chain_split"
        return 1
    fi
    for block in "$chain_split"/*.pem; do
        if ! openssl x509 -in "$block" -noout >/dev/null 2>&1; then
            echo "  malformed certificate in the chain: $block"
            rm -rf "$chain_split"
            return 1
        fi
    done
    echo "  chain: ${count} certificate(s)"
    rm -rf "$chain_split"

    cert_hash=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}')
    key_hash=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}')
    if [ -z "$cert_hash" ] || [ -z "$key_hash" ]; then
        echo "  cannot extract the public key from the staged pair"
        return 1
    fi
    if [ "$cert_hash" != "$key_hash" ]; then
        echo "  certificate and private key do not belong to the same pair"
        return 1
    fi
    subject=$(openssl x509 -in "$cert" -noout -subject | sed 's/^subject= *//')
    not_after=$(openssl x509 -in "$cert" -noout -enddate | sed 's/^notAfter=//')
    echo "  subject: ${subject:-unknown}"
    echo "  expires: ${not_after:-unknown}"
    if ! openssl x509 -in "$cert" -noout -checkend 604800 >/dev/null 2>&1; then
        echo "  Warning: certificate expires within 7 days or has already expired"
    fi
    return 0
}

# Fingerprint of a certificate and key pair, empty when a file is missing or
# unreadable. Content-based, so a renewal that preserves mtime is detected.
#
# This hashes exactly the byte stream tls_publish_pair assembles into the
# published PEM: the key followed by the certificate chain. It has to, or the
# result could never be compared with tls_installed_fingerprint and the watcher
# would republish an unchanged certificate on every tick.
tls_pair_fingerprint() {
    local cert="$1" key="$2" temp output
    [ -r "$cert" ] && [ -r "$key" ] || return 1
    mkdir -p "$TLS_STATE_DIR" || return 1
    temp=$(mktemp "${TLS_STATE_DIR}/.fingerprint.XXXXXX") || return 1
    chmod 600 "$temp" || { rm -f "$temp"; return 1; }
    if ! cat "$key" "$cert" > "$temp" 2>/dev/null; then
        rm -f "$temp"
        return 1
    fi
    output=$(sha256sum "$temp" 2>/dev/null) || { rm -f "$temp"; return 1; }
    rm -f "$temp"
    printf '%s\n' "${output%% *}"
}

# Fingerprint of the pair Postfix currently serves.
tls_installed_fingerprint() {
    local output
    [ -r "$TLS_CHAIN_FILE" ] || return 1
    output=$(sha256sum "$TLS_CHAIN_FILE" 2>/dev/null) || return 1
    printf '%s\n' "${output%% *}"
}

# Keep the live pair and at most TLS_GENERATIONS-1 newest prior generations,
# so the pair being served is never collected from under Postfix.
tls_prune_generations() {
    local live gen keep index
    live=$(readlink "${TLS_STATE_DIR}/live" 2>/dev/null || true)
    keep=$((TLS_GENERATIONS - 1))
    index=0
    for gen in $(ls -1d "${TLS_STATE_DIR}"/gen.* 2>/dev/null | sort -r); do
        [ "$gen" = "$live" ] && continue
        index=$((index + 1))
        if [ "$index" -gt "$keep" ]; then
            rm -rf "$gen"
        fi
    done
    return 0
}

# Publish the pair Postfix reads. The key is written before the certificate, as
# smtpd_tls_chain_files requires.
tls_apply_postfix_conf() {
    postconf -e "smtpd_tls_chain_files = $TLS_CHAIN_FILE" || return 1
    # Postfix ignores the legacy key and certificate parameters once
    # smtpd_tls_chain_files is set, and warns while they are still non-empty.
    postconf -e "smtpd_tls_cert_file =" || return 1
    postconf -e "smtpd_tls_key_file =" || return 1
}

# Copy the source pair into a fresh generation directory as one combined PEM,
# validate the staged files, then publish the directory with a single symlink
# rename. The source can be rewritten by the host at any point, so nothing that
# is not a usable pair ever reaches the live path.
tls_publish_pair_locked() {
    local cert="$1" key="$2" gen live_tmp

    if [ ! -e "$cert" ]; then
        echo "  certificate file not found: $cert"
        return 1
    fi
    if [ ! -e "$key" ]; then
        echo "  private key file not found: $key"
        return 1
    fi
    if [ ! -r "$cert" ] || [ ! -r "$key" ]; then
        echo "  not readable by the container (uid $(id -u)): $cert $key"
        return 1
    fi
    mkdir -p "$TLS_STATE_DIR" || return 1
    # Unique per call: the same process can publish twice within one second
    # (startup publishes, then a renewal or an explicit re-publish follows).
    gen="${TLS_STATE_DIR}/gen.$(date -u '+%Y%m%d%H%M%S%N').$$.${RANDOM}"
    # Private directory and a restrictive umask in a subshell, so key material
    # never lands on disk with default permissions, not even while it is being
    # written or if the copy is interrupted.
    mkdir -m 700 "$gen" || return 1
    if ! ( umask 077
            cat "$key" > "$gen/privkey.pem" &&
            cat "$cert" > "$gen/fullchain.pem" ) 2>/dev/null; then
        echo "  could not read ${cert} / ${key}"
        rm -rf "$gen"
        return 1
    fi
    # Validate the staged copies, not the source: a host renewal or a mounted
    # secret rotation between validation and copying must not decide what is
    # served.
    if ! tls_validate_pair "$gen/fullchain.pem" "$gen/privkey.pem"; then
        rm -rf "$gen"
        return 1
    fi
    # Key first, then the chain, in the file Postfix reads.
    if ! ( umask 077; cat "$gen/privkey.pem" "$gen/fullchain.pem" > "$gen/tls.pem" ) 2>/dev/null; then
        echo "  could not assemble the combined PEM"
        rm -rf "$gen"
        return 1
    fi
    if ! chown root:postfix "$gen/tls.pem" 2>/dev/null ||
       ! chmod 750 "$gen" || ! chmod 640 "$gen/tls.pem"; then
        echo "  could not secure the published certificate permissions"
        rm -rf "$gen"
        return 1
    fi
    rm -f "$gen/privkey.pem" "$gen/fullchain.pem"
    # One rename publishes the pair: no Postfix process can read a new
    # certificate with an old key, and a failure here leaves the previous pair
    # in place.
    # Use a per-invocation symlink name so simultaneous publishers do not
    # replace or remove each other's staging links.
    live_tmp="${TLS_STATE_DIR}/live.new.$$.$RANDOM"
    ln -s "$gen" "$live_tmp" || { rm -rf "$gen"; return 1; }
    if ! mv -Tf "$live_tmp" "${TLS_STATE_DIR}/live" 2>/dev/null; then
        echo "  could not activate the new certificate"
        rm -f "$live_tmp"
        rm -rf "$gen"
        return 1
    fi
    tls_prune_generations
    return 0
}

# Serialize publication and pruning. Without this lock, one publisher could
# prune another publisher's staged generation before its symlink is activated.
# flock holds the lock for the whole subshell, including every early return.
tls_publish_pair() {
    mkdir -p "$TLS_STATE_DIR" || return 1
    (
        flock -x 9 || exit 1
        tls_publish_pair_locked "$@"
    ) 9>"${TLS_STATE_DIR}/.publish.lock"
}

# Re-point Postfix at the self-signed certificates. Needed on the fallback path:
# tls_apply_postfix_conf clears smtpd_tls_cert_file and smtpd_tls_key_file and
# sets smtpd_tls_chain_files, and main.cf lives in the container layer, so
# without this a later fallback would generate self-signed files that Postfix
# never selects and keep serving the previously published pair.
tls_apply_self_signed_conf() {
    postconf -e "smtpd_tls_chain_files =" || return 1
    postconf -e "smtpd_tls_cert_file = /etc/ssl/postfix/certs/postfix.crt" || return 1
    postconf -e "smtpd_tls_key_file = /etc/ssl/postfix/private/postfix.key" || return 1
}

# Reload Postfix, but only when it is running: acme.sh runs this through
# --reloadcmd during startup, before the Postfix daemon has been started.
tls_reload_if_running() {
    if postfix status >/dev/null 2>&1; then
        postfix reload
        return $?
    fi
    echo "Postfix is not running yet, the new pair applies when it starts"
    return 0
}

# Command line entry point, used as the acme.sh --reloadcmd. Guarded so that
# sourcing this file from the entrypoint does not run it: ${BASH_SOURCE[0]} is
# this file's path, $0 the caller's.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ $# -ne 2 ]; then
        echo "Usage: tls-publish.sh <cert-file> <key-file>" >&2
        exit 2
    fi
    tls_publish_pair "$1" "$2" || exit 1
    tls_apply_postfix_conf || exit 1
    tls_reload_if_running || exit 1
fi
