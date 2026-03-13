#!/usr/bin/env bash
# SIP-TLS setup for Issabel (chan_sip) — short, idempotent, no firewall edits.
# Options precedence: (-c/-k) > (-p) > (-d) > existing asterisk.pem > self-signed.
set -euo pipefail

CERT_SRC=""
KEY_SRC=""
PEM_SRC=""
LE_DOMAIN=""
TLS_PORT=5061

while getopts "c:k:p:d:" opt; do
  case "$opt" in
    c) CERT_SRC="$OPTARG" ;;
    k) KEY_SRC="$OPTARG" ;;
    p) PEM_SRC="$OPTARG" ;;
    d) LE_DOMAIN="$OPTARG" ;;
  esac
done

ASTK_DIR="/etc/asterisk/keys"
CRT="$ASTK_DIR/asterisk.crt"
KEY="$ASTK_DIR/asterisk.key"
PEM="$ASTK_DIR/asterisk.pem"
SIP_GEN_CUSTOM="/etc/asterisk/sip_general_custom.conf"

must_root() { [[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }; }
have() { command -v "$1" >/dev/null 2>&1; }

split_pem() { # $1 pem_in
  local pem_in="$1"
  awk 'p;/BEGIN CERTIFICATE/{p=1} /END CERTIFICATE/{exit}' "$pem_in" > "$CRT"
  awk 'f||/PRIVATE KEY/ {f=1; print}' "$pem_in" > "$KEY"
}

copy_ck() { # $1 cert $2 key
  cp "$1" "$CRT"
  cp "$2" "$KEY"
}

ensure_dirs() {
  mkdir -p "$ASTK_DIR"
  touch "$SIP_GEN_CUSTOM"
}

write_conf_block() {
  # Remove previous block
  sed -i '/^; *BEGIN-SIP-TLS/,/^; *END-SIP-TLS/d' "$SIP_GEN_CUSTOM"
  cat >> "$SIP_GEN_CUSTOM" <<EOF
tlsenable=yes
tlsbindaddr=0.0.0.0:${TLS_PORT}
tlscertfile=${CRT}
tlsprivatekey=${KEY}
tlscafile=/etc/ssl/certs/ca-bundle.crt
tlsclientmethod=tlsv1_2
tlsservercipherorder=yes
EOF
}

set_perms() {
  chown asterisk:asterisk "$CRT" "$KEY" 2>/dev/null || true
  chmod 600 "$KEY" 2>/dev/null || true
}

reload_ast() {
  if have asterisk; then
    asterisk -rx "core reload" || systemctl restart asterisk || true
  fi
}

same_modulus() {
  openssl rsa  -in "$KEY" -noout -modulus 2>/dev/null | openssl md5
  openssl x509 -in "$CRT" -noout -modulus 2>/dev/null | openssl md5
}

generate_self_signed() {
  local fqdn="$(hostname -f 2>/dev/null || hostname)"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$KEY" -out "$CRT" \
    -subj "/C=PK/ST=Punjab/L=Faisalabad/O=Issabel PBX/CN=${fqdn}"
}

main() {
  must_root
  ensure_dirs

  if [[ -n "$CERT_SRC" && -n "$KEY_SRC" ]]; then
    copy_ck "$CERT_SRC" "$KEY_SRC"
  elif [[ -n "$PEM_SRC" ]]; then
    split_pem "$PEM_SRC"
  elif [[ -n "$LE_DOMAIN" && -d "/etc/letsencrypt/live/$LE_DOMAIN" ]]; then
    copy_ck "/etc/letsencrypt/live/$LE_DOMAIN/fullchain.pem" \
            "/etc/letsencrypt/live/$LE_DOMAIN/privkey.pem"
  elif [[ -f "$PEM" ]]; then
    # Try to split existing /etc/asterisk/keys/asterisk.pem
    if grep -q "BEGIN PRIVATE KEY" "$PEM"; then
      split_pem "$PEM"
    else
      echo "[!] $PEM has no private key. Falling back to self-signed."
      generate_self_signed
    fi
  else
    echo "[i] No cert/key provided/found. Generating self-signed."
    generate_self_signed
  fi

  set_perms
  write_conf_block
  reload_ast

  echo
  echo "==== SIP-TLS Configured ========================"
  echo "Cert: $CRT"
  echo "Key : $KEY"
  echo "Port: $TLS_PORT"
  echo "Conf: $SIP_GEN_CUSTOM"
  echo
  echo "Verify in CLI:"
  echo "  asterisk -rvvvvv"
  echo "  *CLI> sip show settings | grep -i tls"
  echo
  echo "Hash check (cert vs key modulus):"
  same_modulus || true
  echo "==============================================="
}

main "$@"
