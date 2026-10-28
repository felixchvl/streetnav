#!/bin/sh
# Creates the private CA trusted by Caddy (once) and a client certificate for one device, packed
# as PKCS#12 for the iOS app. Keep OUTPUT_DIR off the repository: it holds private keys.
#   make-client-cert.sh OUTPUT_DIR [DEVICE_NAME]   (openssl asks for the .p12 password)
set -eu
dir=${1:?usage: make-client-cert.sh OUTPUT_DIR [DEVICE_NAME]}
name=${2:-iphone}
umask 077
mkdir -p "$dir"
cd "$dir"

if [ ! -f ca.key ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
    -subj "/CN=Streetnav client CA" -keyout ca.key -out ca.pem
fi
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=streetnav-$name" \
  -keyout "$name.key" -out "$name.csr"
printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n' > "$name.ext"
openssl x509 -req -in "$name.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -days 825 \
  -extfile "$name.ext" -out "$name.pem"
# SHA-1/3DES PKCS#12 is what SecPKCS12Import reliably reads.
openssl pkcs12 -export -inkey "$name.key" -in "$name.pem" -certfile ca.pem -name "Streetnav $name" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -out "$name.p12"
rm -f "$name.csr" "$name.ext"
echo "CA for Caddy: $dir/ca.pem   device bundle: $dir/$name.p12"
