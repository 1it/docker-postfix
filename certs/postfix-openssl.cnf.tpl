[ req ]
default_bits = 2048
default_md = sha256
prompt = no
encrypt_key = no
distinguished_name = dn
req_extensions = req_ext

[ dn ]
C = SSL_COUNTRY
ST = SSL_STATE
L = SSL_LOCALITY
O = SSL_ORGANIZATION
OU = SSL_ORGANIZATIONAL_UNIT
CN = SSL_COMMON_NAME
emailAddress = postmaster@DOMAIN

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = DOMAIN
DNS.2 = mail.DOMAIN
DNS.3 = smtp.DOMAIN

[ cert_type ]
nsCertType = server
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, emailProtection
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = @alt_names

