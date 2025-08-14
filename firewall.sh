#!/usr/bin/env bash
set -euo pipefail

# =====================
# Config (override with flags)
# =====================
ADMIN_USER="admin"           # Issabel web admin (BasicAuth)
ADMIN_PASS=""                # If empty, will prompt
PORT=446                     # Public HTTPS validation port
KEEP_SSH_FOR_CURRENT_IP=1    # Keep current SSH IP on port 22 to avoid lockout

# Paths/vars
APACHE_USER="apache"         # will be auto-detected (non-root worker)
VALIDATE_DIR="/var/www/validate"
HTPASSWD_FILE="/etc/httpd/.validate_htpasswd"
VHOST_FILE="/etc/httpd/conf.d/validate-portal-${PORT}.conf"
CERT_KEY="/etc/pki/tls/private/validate.key"
CERT_CRT="/etc/pki/tls/certs/validate.crt"
ALLOW_SCRIPT="/usr/local/bin/validate-allow-ip.sh"
SUDOERS_FILE="/etc/sudoers.d/validate-allow"
WL_FILE="/etc/validate_ip_whitelist.txt"
SERVERNAME_CONF="/etc/httpd/conf.d/servername.conf"

usage(){ echo "Usage: sudo bash $0 [-u admin] [-p password] [-P 446]"; }
while getopts ":u:p:P:" opt; do
  case $opt in
    u) ADMIN_USER="$OPTARG";;
    p) ADMIN_PASS="$OPTARG";;
    P) PORT="$OPTARG"; VHOST_FILE="/etc/httpd/conf.d/validate-portal-${PORT}.conf";;
    *) usage; exit 1;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "[ERROR] Run as root"; exit 1; }

if [[ -z "$ADMIN_PASS" ]]; then
  read -rsp "Enter Issabel web admin password for '$ADMIN_USER': " ADMIN_PASS; echo
fi

# =====================
# Helper functions
# =====================
ensure_cent7_vault() {
  if grep -q "CentOS.* 7" /etc/redhat-release 2>/dev/null; then
    if ! yum -q repolist >/dev/null 2>&1; then
      echo "[INFO] Enabling CentOS-7 vault repos..."
      cp -f /etc/yum.repos.d/CentOS-Base.repo{,.bak} 2>/dev/null || true
      cat > /etc/yum.repos.d/CentOS-Base.repo <<'EOF'
[base]
name=CentOS-7 - Base
baseurl=http://vault.centos.org/7.9.2009/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-7 - Updates
baseurl=http://vault.centos.org/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-7 - Extras
baseurl=http://vault.centos.org/7.9.2009/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
EOF
      yum clean all || true
      yum -y makecache fast || true
    fi
  fi
}

install_packages() {
  ensure_cent7_vault
  yum -y install httpd mod_ssl php php-cli openssl httpd-tools iptables-services >/dev/null 2>&1 || true
  yum -y install policycoreutils-python >/devnull 2>&1 || yum -y install policycoreutils-python-utils >/dev/null 2>&1 || true
  systemctl enable httpd || true
}

# Detect the actual non-root Apache worker user (apache/asterisk)
detect_web_user() {
  local u confu psu
  confu=$(awk '/^\s*User\s+/{print $2}' /etc/httpd/conf/httpd.conf 2>/dev/null | tail -n1)
  psu=$(ps -eo user,comm | awk '$2=="httpd" && $1!="root"{print $1}' | sort -u | head -n1)
  if [[ -n "${confu:-}" && "${confu}" != "root" ]]; then
    u="$confu"
  elif [[ -n "${psu:-}" ]]; then
    u="$psu"
  else
    u="apache"
  fi
  APACHE_USER="$u"
  echo "[INFO] Web worker user: $APACHE_USER"
}

set_servername() {
  local sname
  sname=$(hostname -f 2>/dev/null || true)
  if [[ -z "$sname" ]]; then sname=$(hostname -I | awk '{print $1}'); fi
  echo "ServerName ${sname}" > "$SERVERNAME_CONF"
}

set_ssl() {
  mkdir -p "$(dirname "$CERT_KEY")" "$(dirname "$CERT_CRT")"
  if [[ ! -f "$CERT_KEY" || ! -f "$CERT_CRT" ]]; then
    openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
      -keyout "$CERT_KEY" -out "$CERT_CRT" \
      -subj "/CN=$(hostname -f 2>/dev/null || hostname -I | awk '{print $1}')"
    chmod 600 "$CERT_KEY"
  fi
}

write_vhost() {
  local SNAME
  SNAME=$(hostname -f 2>/dev/null || hostname -I | awk '{print $1}')
  cat > "$VHOST_FILE" <<CONF
Listen $PORT
<VirtualHost *:$PORT>
  ServerName $SNAME
  DocumentRoot $VALIDATE_DIR
  DirectoryIndex validate.php
  SSLEngine on
  SSLCertificateFile $CERT_CRT
  SSLCertificateKeyFile $CERT_KEY
  <Directory $VALIDATE_DIR>
    Options -Indexes +FollowSymLinks
    AllowOverride None
    AuthType Basic
    AuthName "Globilinks Validate"
    AuthUserFile $HTPASSWD_FILE
    Require valid-user
  </Directory>
  ErrorLog logs/validate-${PORT}-error.log
  CustomLog logs/validate-${PORT}-access.log combined
</VirtualHost>
CONF
}

write_app() {
  mkdir -p "$VALIDATE_DIR"
  cat > "$VALIDATE_DIR/validate.php" <<'PHP'
<?php
// Whitelist client IP then REDIRECT WITHOUT PORT to HTTP
$clientIp = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
if (!filter_var($clientIp, FILTER_VALIDATE_IP)) { header('HTTP/1.0 400 Bad Request'); exit('Invalid client IP'); }
$cmd = '/usr/local/bin/validate-allow-ip.sh ' . escapeshellarg($clientIp);
$out = array(); $rc = 1;
// absolute path to sudo; PHP 5.4 compatible
exec('/usr/bin/sudo -n ' . $cmd . ' 2>&1', $out, $rc);
if ($rc === 0) {
  $host = isset($_SERVER['SERVER_NAME']) ? $_SERVER['SERVER_NAME'] : (isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : '');
  $host = preg_replace('/:.*/', '', $host); // strip :port
  header('Location: http://' . $host . '/', true, 302); // HTTP, NO PORT
  exit;
}
header('Content-Type: text/plain; charset=UTF-8');
header('HTTP/1.0 500 Internal Server Error');
echo "Failed to whitelist IP\n";
echo implode("\n", $out);
PHP

  chmod 755 /var/www || true
  chmod 755 "$VALIDATE_DIR"
  chown -R "$APACHE_USER":"$APACHE_USER" "$VALIDATE_DIR"
  chmod 644 "$VALIDATE_DIR/validate.php"
}

set_basicauth() {
  chmod 755 /etc/httpd || true
  htpasswd -bc "$HTPASSWD_FILE" "$ADMIN_USER" "$ADMIN_PASS"
  chown root:"$APACHE_USER" "$HTPASSWD_FILE"
  chmod 640 "$HTPASSWD_FILE"
  restorecon -v "$HTPASSWD_FILE" >/dev/null 2>&1 || true
}

write_helper() {
  cat > "$ALLOW_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
IP="$1"
[[ -z "$IP" ]] && { echo "No IP"; exit 1; }
if ! echo "$IP" | grep -Eq '^[0-9\.]+$|:'; then echo "Bad IP"; exit 1; fi
WL_FILE="/etc/validate_ip_whitelist.txt"
CHAIN="VALIDATEWL"
iptables -nL $CHAIN >/dev/null 2>&1 || iptables -N $CHAIN
iptables -C INPUT -j $CHAIN 2>/dev/null || iptables -I INPUT 1 -j $CHAIN
iptables -C $CHAIN -s "$IP" -j ACCEPT 2>/dev/null || iptables -A $CHAIN -s "$IP" -j ACCEPT
mkdir -p "$(dirname "$WL_FILE")"
grep -q "^$IP$" "$WL_FILE" 2>/dev/null || echo "$IP" >> "$WL_FILE"
if command -v service >/dev/null 2>&1; then service iptables save || true; fi
if command -v iptables-save >/dev/null 2>&1; then iptables-save > /etc/sysconfig/iptables || true; fi
SH
  chmod 755 "$ALLOW_SCRIPT"
}

set_sudoers() {
  cat > "$SUDOERS_FILE" <<EOF
Defaults:$APACHE_USER !requiretty, !authenticate
Defaults:apache       !requiretty, !authenticate
Defaults:asterisk     !requiretty, !authenticate
Cmnd_Alias VALIDATE = $ALLOW_SCRIPT
$APACHE_USER ALL=(root) NOPASSWD: VALIDATE
apache       ALL=(root) NOPASSWD: VALIDATE
asterisk     ALL=(root) NOPASSWD: VALIDATE
EOF
  chown root:root "$SUDOERS_FILE"
  chmod 0440 "$SUDOERS_FILE"
  visudo -cf "$SUDOERS_FILE" >/dev/null
}

set_selinux() {
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    echo "[INFO] SELinux enforcing: applying contexts & port mapping"
    semanage fcontext -a -t httpd_sys_content_t "$VALIDATE_DIR(/.*)?" || true
    restorecon -Rv "$VALIDATE_DIR" || true
    semanage fcontext -a -t httpd_sys_script_exec_t "$ALLOW_SCRIPT" || true
    restorecon -v "$ALLOW_SCRIPT" || true
    semanage port -a -t http_port_t -p tcp "$PORT" 2>/dev/null || semanage port -m -t http_port_t -p tcp "$PORT" || true
    setsebool -P httpd_can_network_connect 1 || true
  fi
}

set_iptables() {
  iptables -nL VALIDATEWL >/dev/null 2>&1 || iptables -N VALIDATEWL
  iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -A INPUT -i lo -j ACCEPT
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
  if [[ "$KEEP_SSH_FOR_CURRENT_IP" == "1" && -n "${SSH_CLIENT:-}" ]]; then
    CURR_IP="${SSH_CLIENT%% *}"
    if [[ -n "$CURR_IP" ]]; then
      iptables -C INPUT -p tcp --dport 22 -s "$CURR_IP" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 22 -s "$CURR_IP" -j ACCEPT
    fi
  fi
  iptables -C INPUT -j VALIDATEWL 2>/dev/null || iptables -I INPUT 1 -j VALIDATEWL
  iptables -C INPUT -j DROP 2>/dev/null || iptables -A INPUT -j DROP
  service iptables save || true
  iptables-save > /etc/sysconfig/iptables || true
  systemctl enable iptables || true
  systemctl restart iptables || true
}

main() {
  install_packages
  detect_web_user
  set_servername
  set_ssl
  write_vhost
  write_app
  set_basicauth
  write_helper
  set_sudoers
  set_selinux
  apachectl -t
  systemctl restart httpd
  set_iptables

  if command -v php >/dev/null 2>&1 && php -i 2>/dev/null | grep -i '^disable_functions' | grep -q 'exec'; then
    echo "[WARN] PHP 'exec' is disabled in php.ini. Enable it for validate.php to call sudo."
  fi

  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo -e "\n[OK] Validate portal installed."
  echo "Open: https://${ip:-YOUR_SERVER}:$PORT/validate.php"
}

main "$@"