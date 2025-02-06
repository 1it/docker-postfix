[ req ]
default_bits = 4096
default_md = sha256
prompt = no
encrypt_key = no
distinguished_name = dn
x509_extensions = cert_type

[ dn ]
C = SSL_COUNTRY
ST = SSL_STATE
L = SSL_LOCALITY
O = SSL_ORGANIZATION
OU = SSL_ORGANIZATIONAL_UNIT
CN = SSL_COMMON_NAME
emailAddress = postmaster@DOMAIN

[ cert_type ]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
