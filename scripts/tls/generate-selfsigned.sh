#!/usr/bin/env bash
# Generate a self-signed certificate for the Boutique edge, importable into ACM.
#
# This is the development path. SPEC.md non-goal 7: there is no Route 53 zone in
# the account, so a DNS-validated certificate from a public CA is impossible.
# scripts/tls/generate-selfsigned.sh produces a cert that is a real TLS chain
# with a CA we generated, so a browser warns.
#
# It prints nothing sensitive to stdout. The private key is written to a
# gitignored path, and only the ACM import command is printed.
set -euo pipefail

OUT_DIR="${OUT_DIR:-$HOME/.boutique-platform/tls}"
HOSTS="${HOSTS:-boutique.local,localhost,*.ip.sslip.io}"
DAYS="${DAYS:-825}"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

KEY="$OUT_DIR/edge.key"
CRT="$OUT_DIR/edge.crt"

if [[ -f "$KEY" ]]; then
  printf 'Reusing existing key at %s\n' "$KEY"
else
  openssl genrsa -out "$KEY" 4096 2>/dev/null
  chmod 600 "$KEY"
fi

SAN=$(printf '%s' "$HOSTS" | tr ',' '\n' | sed 's/^/DNS:/' | paste -sd, -)

openssl req -new -x509 -key "$KEY" -out "$CRT" -days "$DAYS" -sha256 \
  -subj "/CN=${HOSTS%%,*}/O=boutique-platform" \
  -addext "subjectAltName=${SAN}" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=serverAuth" 2>/dev/null

# A chain file: for a self-signed cert the chain is the cert itself, which is
# what ACM's import expects for certificate_chain.
cp "$CRT" "$OUT_DIR/edge-chain.crt"

cat <<EOF
Wrote:
  key    $KEY
  cert   $OUT_DIR/edge.crt
  chain  $OUT_DIR/edge-chain.crt

The key is NOT in this output. It is at $KEY with mode 600, and
$OUT_DIR is gitignored.

Import into ACM (paste these into a terminal, they read the files):

  aws acm import-certificate --region us-east-1 \\
    --certificate "fileb://$OUT_DIR/edge.crt" \\
    --private-key  "fileb://$KEY" \\
    --certificate-chain "fileb://$OUT_DIR/edge-chain.crt"

Then set the returned ARN in the platform tfvars as acm_certificate_arn, or pass
it at apply time:

  TF_VAR_acm_certificate_arn=arn:aws:acm:... TF_VAR_acm_private_key=\$(cat $KEY) \\
    TF_VAR_acm_certificate_body=\$(cat $OUT_DIR/edge.crt) \\
    TF_VAR_acm_certificate_chain=\$(cat $OUT_DIR/edge-chain.crt) \\
    terraform -chdir=platform apply
EOF
