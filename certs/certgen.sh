#!/bin/bash

set -e

echo "Starting certificate generation for ${DOMAIN}..."

# Default values
DOMAIN=${DOMAIN:-"mail.example.com"}
SSL_COUNTRY=${SSL_COUNTRY:-"US"}
SSL_STATE=${SSL_STATE:-"State"}
SSL_LOCALITY=${SSL_LOCALITY:-"City"}
SSL_ORGANIZATION=${SSL_ORGANIZATION:-"Organization"}
SSL_ORGANIZATIONAL_UNIT=${SSL_ORGANIZATIONAL_UNIT:-"IT"}
SSL_COMMON_NAME=${SSL_COMMON_NAME:-${DOMAIN}}
SSL_DIR=${SSL_DIR:-"/etc/ssl"}
SSL_POSTFIX_DIR=${SSL_POSTFIX_DIR:-"/etc/ssl/postfix"}

# Create directories if they don't exist
mkdir -p ${SSL_DIR}/private
mkdir -p ${SSL_DIR}/certs
mkdir -p ${SSL_POSTFIX_DIR}/private
mkdir -p ${SSL_POSTFIX_DIR}/certs

# Create temporary OpenSSL config files with replaced variables
for conf in ${SSL_DIR}/*.cnf.tpl; do
    generated_conf="${conf%.tpl}"
    cp "$conf" "$generated_conf"
    sed -i \
        -e "s|DOMAIN|${DOMAIN}|g" \
        -e "s|SSL_COUNTRY|${SSL_COUNTRY}|g" \
        -e "s|SSL_STATE|${SSL_STATE}|g" \
        -e "s|SSL_LOCALITY|${SSL_LOCALITY}|g" \
        -e "s|SSL_ORGANIZATION|${SSL_ORGANIZATION}|g" \
        -e "s|SSL_ORGANIZATIONAL_UNIT|${SSL_ORGANIZATIONAL_UNIT}|g" \
        -e "s|SSL_COMMON_NAME|${SSL_COMMON_NAME}|g" \
        -e "s|SSL_EMAIL|${SSL_EMAIL}|g" \
        "$generated_conf"
done

# Generate CA if it doesn't exist
if [ ! -f ${SSL_POSTFIX_DIR}/certs/ca.crt ]; then
    echo "Generating CA private key for ${DOMAIN}"
    openssl genrsa -out ${SSL_POSTFIX_DIR}/private/ca.key 4096

    echo "Generating CA certificate for ${DOMAIN}"
    openssl req -new -x509 -days 3650 -key ${SSL_POSTFIX_DIR}/private/ca.key \
        -out ${SSL_POSTFIX_DIR}/certs/ca.crt -config ${SSL_DIR}/ca-openssl.cnf

    chmod 644 ${SSL_POSTFIX_DIR}/certs/ca.crt
    chmod 600 ${SSL_POSTFIX_DIR}/private/ca.key
fi

# Generate mail server certificate
if [ ! -f ${SSL_POSTFIX_DIR}/certs/postfix.crt ]; then
    echo "Generating mail server private key for ${DOMAIN}"
    openssl genrsa -out ${SSL_POSTFIX_DIR}/private/postfix.key 2048

    echo "Generating mail server CSR for ${DOMAIN}"
    openssl req -new -key ${SSL_POSTFIX_DIR}/private/postfix.key \
        -out ${SSL_POSTFIX_DIR}/certs/postfix.csr -config ${SSL_DIR}/postfix-openssl.cnf

    echo "Signing mail server certificate with CA for ${DOMAIN}"
    openssl x509 -req -days 3650 \
        -in ${SSL_POSTFIX_DIR}/certs/postfix.csr \
        -CA ${SSL_POSTFIX_DIR}/certs/ca.crt \
        -CAkey ${SSL_POSTFIX_DIR}/private/ca.key \
        -CAcreateserial \
        -out ${SSL_POSTFIX_DIR}/certs/postfix.crt \
        -extfile ${SSL_DIR}/postfix-openssl.cnf \
        -extensions cert_type

    chmod 644 ${SSL_POSTFIX_DIR}/certs/postfix.crt
    chmod 600 ${SSL_POSTFIX_DIR}/private/postfix.key
fi

echo "Certificate generation completed successfully!"
