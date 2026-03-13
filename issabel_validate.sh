#!/usr/bin/env bash
# ======================================================================
# Issabel Dynportal-style IP Validation - One-shot installer (validate.sh)
# Target: Issabel on CentOS 7 (PHP 5.4)
# ======================================================================
set -euo pipefail
sed -i 's/\r$//' "$0" >/dev/null 2>&1 || true   # strip CRLF if pasted

# ---------------- Config ----------------
ADMIN_USER="admin"
ADMIN_PASS='ABC@xmenx1690!'                           # requested fixed password
STATIC_SHA='{SHA}HiIF0ii9fdCqqQWSMA6JnJBrAEM='        # sha1 of ABC@xmenx1690!
PORT=446

ALLOW_ALL_PORTS_FOR_WHITELIST=1                       # 1=allow ALL ports for validated IP
KEEP_SSH_FOR_CURRENT_IP=1                             # keep current SSH client safe
KEEP_CIP_PORTS=(22 2008 55554)                        # kept open for current SSH IP (TCP)
FIX_DNS_IF_EMPTY=1                                    # add DNS if resolv.conf has none

# If ALLOW_ALL_PORTS_FOR_WHITELIST=0, only these are opened:
TCP_PORTS=(80 443 2008 22 5061 5038 8088 55554)
UDP_PORTS=(5060 5061 6070 6071 57889)
RTP_UDP_RANGE_START=10000
RTP_UDP_RANGE_END=20000

# ---------------- Paths ----------------
APACHE_USER="apache"
VALIDATE_DIR="/var/www/validate"
HTPASSWD_FILE="/etc/httpd/.validate_htpasswd"
VHOST_FILE="/etc/httpd/conf.d/validate-portal-${PORT}.conf"
CERT_KEY="/etc/pki/tls/private/validate.key"
CERT_CRT="/etc/pki/tls/certs/validate.crt"
ALLOW_SCRIPT="/usr/local/bin/validate-allow-ip.sh"
SUDOERS_FILE="/etc/sudoers.d/validate-allow"
WL_FILE="/etc/validate_ip_whitelist.txt"
SERVERNAME_CONF="/etc/httpd/conf.d/servername.conf"

usage(){ cat <<USAGE
Usage: sudo bash $0 [-P 446] [--allow-all|--ports-list]
USAGE
}

# ---------------- Flags ----------------
while (($#)); do
  case "$1" in
    -P) PORT="$2"; VHOST_FILE="/etc/httpd/conf.d/validate-portal-${PORT}.conf"; shift 2;;
    --allow-all)  ALLOW_ALL_PORTS_FOR_WHITELIST=1; shift 1;;
    --ports-list) ALLOW_ALL_PORTS_FOR_WHITELIST=0; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "[ERROR] Unknown arg: $1"; usage; exit 1;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "[ERROR] Run as root"; exit 1; }

# ---------------- Helpers ----------------
server_ip(){ ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"; }
server_host(){ hostname -f 2>/dev/null || server_ip; }

fix_dns_if_needed(){
  [[ "$FIX_DNS_IF_EMPTY" != "1" ]] && return 0
  grep -qE '^\s*nameserver\s+' /etc/resolv.conf 2>/dev/null || {
    echo "[INFO] Adding resolvers to /etc/resolv.conf (1.1.1.1, 8.8.8.8)"
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" >> /etc/resolv.conf
  }
}

force_cent7_vault_repos(){
  if [[ -f /etc/redhat-release ]] && grep -q "CentOS.* 7" /etc/redhat-release; then
    echo "[INFO] Forcing CentOS-7 repos to vault.centos.org & disabling mirrorlistâ€¦"
    cp -f /etc/yum.repos.d/CentOS-Base.repo{,.bak.$(date +%s)} 2>/dev/null || true
    cat > /etc/yum.repos.d/CentOS-Base.repo <<'EOF'
[base]
name=CentOS-7 - Base
baseurl=http://vault.centos.org/7.9.2009/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
skip_if_unavailable=1
[updates]
name=CentOS-7 - Updates
baseurl=http://vault.centos.org/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
skip_if_unavailable=1
[extras]
name=CentOS-7 - Extras
baseurl=http://vault.centos.org/7.9.2009/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
skip_if_unavailable=1
EOF
    sed -i -E 's/^[[:space:]]*mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/*.repo 2>/dev/null || true
  fi
}

disable_broken_repos(){
  for f in /etc/yum.repos.d/*issabel*.repo /etc/yum.repos.d/*Issabel*.repo /etc/yum.repos.d/*epel*.repo /etc/yum.repos.d/*EPEL*.repo; do
    [[ -f "$f" ]] && { echo "[INFO] Disabling repo file: $f"; mv -f "$f" "${f}.disabled"; }
  done
  for f in /etc/yum.repos.d/*.repo; do
    [[ -f "$f" ]] || continue
    grep -q '^\[commercial-addons\]' "$f" || continue
    sed -i -E '/^\[commercial-addons\]/,/^\[/{s/^[[:space:]]*enabled=1/enabled=0/}' "$f"
  done
}

ensure_repos_ready(){
  fix_dns_if_needed
  force_cent7_vault_repos
  disable_broken_repos
  yum clean all >/dev/null 2>&1 || true
  yum -y makecache fast >/dev/null 2>&1 || true
  yum -q repolist >/dev/null 2>&1 || { echo "[ERROR] YUM repos not reachable. Check DNS/network."; exit 1; }
}

install_packages(){
  ensure_repos_ready
  yum -y install httpd mod_ssl php php-cli openssl httpd-tools iptables-services curl >/dev/null 2>&1 || true
  yum -y install policycoreutils-python >/dev/null 2>&1 || yum -y install policycoreutils-python-utils >/dev/null 2>&1 || true
  systemctl stop firewalld >/dev/null 2>&1 || true
  systemctl disable firewalld >/dev/null 2>&1 || true
  systemctl enable httpd iptables >/dev/null 2>&1 || true
}

detect_web_user(){
  local confu psu
  confu=$(awk '/^\s*User\s+/{print $2}' /etc/httpd/conf/httpd.conf 2>/dev/null | tail -n1 || true)
  psu=$(ps -eo user,comm | awk '$2=="httpd" && $1!="root"{print $1}' | sort -u | head -n1 || true)
  if [[ -n "${confu:-}" && "${confu}" != "root" ]]; then APACHE_USER="$confu"
  elif [[ -n "${psu:-}" ]]; then APACHE_USER="$psu"
  else APACHE_USER="apache"; fi
  echo "[INFO] Web worker user: $APACHE_USER"
}

set_servername(){ echo "ServerName $(server_host)" > "$SERVERNAME_CONF"; }

set_ssl(){
  mkdir -p "$(dirname "$CERT_KEY")" "$(dirname "$CERT_CRT")"
  if [[ ! -f "$CERT_KEY" || ! -f "$CERT_CRT" ]]; then
    openssl req -x509 -nodes -days 825 -newkey rsa:2048 -keyout "$CERT_KEY" -out "$CERT_CRT" -subj "/CN=$(server_host)" >/dev/null 2>&1
    chmod 600 "$CERT_KEY"
  fi
}

write_vhost(){
  # disable other validate-portal-* except ours
  local had_nullglob=0
  if ! shopt -q nullglob; then had_nullglob=1; shopt -s nullglob; fi
  for f in /etc/httpd/conf.d/validate-portal-*.conf; do
    [[ "$f" == "$VHOST_FILE" ]] && continue
    [[ -f "$f" ]] && mv -f "$f" "${f}.disabled"
  done
  (( had_nullglob == 1 )) && shopt -u nullglob || true

  cat > "$VHOST_FILE" <<CONF
Listen $PORT
<VirtualHost *:$PORT>
  ServerName $(server_host)
  DocumentRoot $VALIDATE_DIR
  DirectoryIndex validate.php
  SSLEngine on
  SSLCertificateFile $CERT_CRT
  SSLCertificateKeyFile $CERT_KEY
  <Directory $VALIDATE_DIR>
    Options -Indexes +FollowSymLinks
    AllowOverride None
    Require all granted
  </Directory>
  ErrorLog logs/validate-${PORT}-error.log
  CustomLog logs/validate-${PORT}-access.log combined
</VirtualHost>
CONF

  # ensure no lingering BasicAuth on this docroot
  grep -RlE "<Directory\\s+$VALIDATE_DIR>|DocumentRoot\\s+$VALIDATE_DIR" /etc/httpd/conf.d 2>/dev/null | xargs -r sed -i '/AuthType\|AuthName\|AuthUserFile\|Require[[:space:]]\+valid-user/d'
  rm -f "$VALIDATE_DIR/.htaccess" 2>/dev/null || true
}

write_app(){
  mkdir -p "$VALIDATE_DIR"

  # --- Main portal ---
  cat > "$VALIDATE_DIR/validate.php" <<'PHP'
<?php
define('HTPASSWD_FILE', '/etc/httpd/.validate_htpasswd');
define('ALLOW_EXT_VERIFIER', false); // avoid htpasswd locking
define('STATIC_SHA', '{SHA}HiIF0ii9fdCqqQWSMA6JnJBrAEM='); // fallback for admin/ABC@xmenx1690!

function ip_client(){ return isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : ''; }
function h($s){ return htmlspecialchars($s, ENT_QUOTES, 'UTF-8'); }
function issabel_login_url(){
  $host = isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : (isset($_SERVER['SERVER_NAME']) ? $_SERVER['SERVER_NAME'] : '');
  $host = preg_replace('/:.*/', '', $host);
  return 'http://' . $host . '/';
}
function apr1_check($password, $hash){
  if (strpos($hash, '$apr1$') !== 0) return false;
  $parts = explode('$', $hash); if (count($parts) < 4) return false; $salt = $parts[2];
  $len = strlen($password); $ctx = $password . '$apr1$' . $salt;
  $bin = pack('H*', md5($password . $salt . $password));
  for ($i = $len; $i > 0; $i -= 16) $ctx .= substr($bin, 0, min(16, $i));
  for ($i = $len; $i > 0; $i >>= 1) $ctx .= ($i & 1) ? chr(0) : $password[0];
  $bin = pack('H*', md5($ctx));
  for ($i = 0; $i < 1000; $i++) {
    $new = ($i & 1) ? $password : $bin;
    if ($i % 3) $new .= $salt;
    if ($i % 7) $new .= $password;
    $new .= ($i & 1) ? $bin : $password;
    $bin = pack('H*', md5($new));
  }
  $tmp = ''; $order = array(0,6,12,1,7,13,2,8,14,3,9,15,4,10,5,11);
  foreach ($order as $i) $tmp .= $bin[$i];
  $base64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'; $out = '';
  $pairs = array(array(0,6,12),array(1,7,13),array(2,8,14),array(3,9,15),array(4,10,5),array(11,null,null));
  foreach ($pairs as $p) {
    $v = (ord($tmp[$p[0]]) << 16);
    if ($p[1] !== null) $v |= (ord($tmp[$p[1]]) << 8);
    if ($p[2] !== null) $v |= ord($tmp[$p[2]]);
    for ($i = 0; $i < 4 && ($p[$i] !== null || $i < 2); $i++) { $out = $base64[$v & 0x3f] . $out; $v >>= 6; }
  }
  $encoded = substr($out, -22);
  return ('$apr1$' . $salt . '$' . $encoded) === $hash;
}
function verify_htpasswd_internal($user,$pass){
  $f=HTPASSWD_FILE; $lines=false;
  if (is_readable($f)) { $lines = @file($f); }
  if (is_array($lines)) {
    foreach ($lines as $ln) {
      $ln = trim(str_replace("\r","",$ln)); if ($ln==='') continue;
      $p = explode(':',$ln,2); if (count($p)<2) continue;
      if ($p[0] !== $user) continue;
      $h = trim($p[1]);
      if (strpos($h,'{SHA}')===0){ return ('{SHA}'.base64_encode(sha1($pass,true))===$h); }
      if (strpos($h,'$apr1$')===0){ return apr1_check($pass,$h); }
      $res = crypt($pass,$h); return is_string($res) && $res === $h;
    }
  }
  // fallback: accept static admin hash (never fails for the requested password)
  if ($user==='admin') {
    $calc = '{SHA}'.base64_encode(sha1($pass,true));
    if ($calc === STATIC_SHA) return true;
  }
  return false;
}
$err = ''; $validated = false; $ip = ip_client(); $redir = issabel_login_url();
$dbg = isset($_GET['debug']); // add ?debug=1 to log computed hash on failure

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  $user = isset($_POST['user']) ? $_POST['user'] : ''; $pw = isset($_POST['pass']) ? $_POST['pass'] : '';
  if ($user === '' || $pw === '') $err = 'Please enter User ID and Password.';
  else {
    if (!verify_htpasswd_internal($user, $pw)) {
      if ($dbg){ $calc = '{SHA}'.base64_encode(sha1($pw,true)); error_log('DEBUG auth: user='.$user.' calc='.$calc); }
      $err = 'Invalid credentials.';
    } else {
      $cmd = '/usr/bin/sudo -n /usr/local/bin/validate-allow-ip.sh ' . escapeshellarg($ip) . ' 2>&1';
      $out = array(); $rc = 1; exec($cmd, $out, $rc);
      if ($rc === 0) $validated = true; else $err = 'Failed to whitelist IP: ' . implode(' ', $out);
    }
  }
}
?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Issabel â€“ IP Validation</title>
<style>
:root{--bg:#0b1220;--card:#e9ffe9;--shadow:#b8d1b8;--btn:#5f7a97;--btntext:#fff;--text:#0b0b0b;}
body{margin:0;font-family:system-ui,Segoe UI,Roboto,Arial;background:var(--bg);color:#e8eefc;}
.wrap{max-width:760px;margin:40px auto;padding:0 16px;}
.brand{display:flex;align-items:center;gap:12px;margin-bottom:18px;}
.logo{width:42px;height:42px;border-radius:9px;background:linear-gradient(135deg,#7b61ff 0%, #2dd4bf 100%);box-shadow:0 6px 24px rgba(0,0,0,.25);}
.brand h1{font-size:26px;margin:0;color:#fff}
.card{background:var(--card);color:var(--text);border-radius:10px;box-shadow:0 8px 0 var(--shadow),0 18px 32px rgba(0,0,0,.25);padding:18px 18px 22px;max-width:420px;border:1px solid #d6f0d6;}
.title{font-size:22px;font-weight:700;text-align:center;margin:6px 0 14px}
label{display:block;font-weight:600;margin:12px 0 6px}
input[type=text],input[type=password]{width:100%;padding:10px 12px;border:1px solid #9ab99a;border-radius:6px;background:#fff;font-size:15px}
.btn{margin-top:16px;width:100%;padding:10px 14px;border-radius:8px;border:0;background:var(--btn);color:var(--btntext);font-weight:700;font-size:15px;cursor:pointer}
.msg-ok{color:#0a7a2a;font-weight:700;text-align:center;margin-top:12px}
.msg-err{color:#b00020;font-weight:700;text-align:center;margin:8px 0}
.below{color:#f0f5ff;margin-top:28px;font-size:18px;line-height:1.6}.below a{color:#cfe3ff}.count{color:#ff3b30;font-weight:800}
</style></head>
<body><div class="wrap">
  <div class="brand"><div class="logo"></div><h1>Issabel</h1></div>
  <div class="card"><div class="title">IP Validation</div>
  <?php if ($validated): ?>
    <div class="msg-ok">Login Validated for IP <?php echo h($ip); ?></div>
    <script>var secs=60,url=<?php echo json_encode($redir); ?>;function tick(){var e=document.getElementById('cd');if(e)e.textContent=secs;if(secs<=0)location.href=url;else{secs--;setTimeout(tick,1e3)}}window.addEventListener('DOMContentLoaded',tick);</script>
  <?php else: ?>
    <?php if ($err): ?><div class="msg-err"><?php echo h($err); ?></div><?php endif; ?>
    <form method="post"><label>User ID</label><input type="text" name="user" required>
      <label>Password</label><input type="password" name="pass" required>
      <button class="btn" type="submit">Submit</button></form>
  <?php endif; ?>
  </div>
  <div class="below">
    <?php if ($validated): ?>Redirecting to <a href="<?php echo h($redir); ?>">Login Page</a> in <span class="count" id="cd">60</span> seconds.
    <?php else: ?>Enter your Issabel credentials to enable access for your IP address.<?php endif; ?>
  </div>
</div></body></html>
PHP

  # --- Tiny diag page ---
  cat > "$VALIDATE_DIR/_diag.php" <<'PHP'
<?php
$f='/etc/httpd/.validate_htpasswd';
$ok1 = file_exists($f); $ok2 = is_readable($f);
$lines = $ok2 ? @file($f) : false;
$user=''; $hash='';
if ($lines && isset($lines[0])) { $parts=explode(':', trim(str_replace("\r","",$lines[0])), 2); $user=$parts[0]; $hash=isset($parts[1])?trim($parts[1]):''; }
$calc = '{SHA}'.base64_encode(sha1('ABC@xmenx1690!', true));
echo 'exists='.(int)$ok1.' readable='.(int)$ok2.' lines='.(is_array($lines)?count($lines):0).
     ' user='.$user.' hash='.$hash.' calc_sha='.$calc."\n";
PHP

  # --- Simple index ---
  cat > "$VALIDATE_DIR/index.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><title>Issabel â€“ IP Validation</title></head>
<body style="font-family:system-ui;background:#0b1220;color:#e8eefc;display:flex;min-height:100vh;align-items:center;justify-content:center">
  <div>Open <code>/validate.php</code> to validate your IP.</div>
</body></html>
HTML

  chmod 755 /var/www || true
  chmod 755 "$VALIDATE_DIR"
  chown -R "$APACHE_USER":"$APACHE_USER" "$VALIDATE_DIR"
  chmod 644 "$VALIDATE_DIR/validate.php" "$VALIDATE_DIR/_diag.php" "$VALIDATE_DIR/index.html"
}

create_htpasswd(){
  printf "%s:%s\n" "$ADMIN_USER" "$STATIC_SHA" > "$HTPASSWD_FILE"
  sed -i 's/\r$//' "$HTPASSWD_FILE" 2>/dev/null || true
  chown root:apache "$HTPASSWD_FILE" 2>/dev/null || true
  chmod 640 "$HTPASSWD_FILE" 2>/dev/null || true
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t httpd_sys_content_t "$HTPASSWD_FILE" 2>/dev/null || true
    restorecon -v "$HTPASSWD_FILE" >/dev/null 2>&1 || true
  fi
}

write_helper(){
  local tcp_list udp_list
  tcp_list="$(printf "%s " "${TCP_PORTS[@]}")"
  udp_list="$(printf "%s " "${UDP_PORTS[@]}")"

  cat > "$ALLOW_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
IP="${1:-}"
[[ -z "$IP" ]] && { echo "No IP"; exit 1; }
if ! echo "$IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$|:'; then echo "Bad IP"; exit 1; fi
WL_FILE="__WL_FILE__"
CHAIN="VALIDATEWL"
ALLOW_ALL="__ALLOW_ALL__"
TCP_LIST="__TCP_LIST__"
UDP_LIST="__UDP_LIST__"
RTP_START="__RTP_START__"
RTP_END="__RTP_END__"
iptables -nL "$CHAIN" >/dev/null 2>&1 || iptables -N "$CHAIN"
iptables -C INPUT -j "$CHAIN" 2>/dev/null || iptables -I INPUT 1 -j "$CHAIN"
if [[ "$ALLOW_ALL" == "1" ]]; then
  iptables -C "$CHAIN" -s "$IP" -j ACCEPT 2>/dev/null || iptables -A "$CHAIN" -s "$IP" -j ACCEPT
else
  for P in $TCP_LIST; do iptables -C "$CHAIN" -p tcp -s "$IP" --dport "$P" -j ACCEPT 2>/dev/null || iptables -A "$CHAIN" -p tcp -s "$IP" --dport "$P" -j ACCEPT; done
  for P in $UDP_LIST; do iptables -C "$CHAIN" -p udp -s "$IP" --dport "$P" -j ACCEPT 2>/dev/null || iptables -A "$CHAIN" -p udp -s "$IP" --dport "$P" -j ACCEPT; done
  iptables -C "$CHAIN" -p udp -s "$IP" --dport "$RTP_START":"$RTP_END" -j ACCEPT 2>/dev/null || iptables -A "$CHAIN" -p udp -s "$IP" --dport "$RTP_START":"$RTP_END" -j ACCEPT
fi
grep -q "^$IP$" "$WL_FILE" 2>/dev/null || echo "$IP" >> "$WL_FILE"
service iptables save >/dev/null 2>&1 || true
iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
echo "[OK] Whitelisted $IP"
SH
  sed -i "s|__WL_FILE__|$WL_FILE|g" "$ALLOW_SCRIPT"
  sed -i "s|__ALLOW_ALL__|$ALLOW_ALL_PORTS_FOR_WHITELIST|g" "$ALLOW_SCRIPT"
  sed -i "s|__TCP_LIST__|$tcp_list|g" "$ALLOW_SCRIPT"
  sed -i "s|__UDP_LIST__|$udp_list|g" "$ALLOW_SCRIPT"
  sed -i "s|__RTP_START__|$RTP_UDP_RANGE_START|g" "$ALLOW_SCRIPT"
  sed -i "s|__RTP_END__|$RTP_UDP_RANGE_END|g" "$ALLOW_SCRIPT"
  chmod 755 "$ALLOW_SCRIPT"
}

set_sudoers(){
  cat > "$SUDOERS_FILE" <<EOF
Defaults:$APACHE_USER !requiretty, !authenticate
Cmnd_Alias VALIDATE = $ALLOW_SCRIPT
$APACHE_USER ALL=(root) NOPASSWD: VALIDATE
EOF
  chown root:root "$SUDOERS_FILE"
  chmod 0440 "$SUDOERS_FILE"
  visudo -cf "$SUDOERS_FILE" >/dev/null
}

set_selinux(){
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    semanage fcontext -a -t httpd_sys_content_t "$VALIDATE_DIR(/.*)?" 2>/dev/null || true
    restorecon -Rv "$VALIDATE_DIR" >/dev/null 2>&1 || true
    semanage fcontext -a -t httpd_sys_script_exec_t "$ALLOW_SCRIPT" 2>/dev/null || true
    restorecon -v "$ALLOW_SCRIPT" >/dev/null 2>&1 || true
    semanage fcontext -a -t httpd_sys_content_t "$HTPASSWD_FILE" 2>/dev/null || true
    restorecon -v "$HTPASSWD_FILE" >/dev/null 2>&1 || true
    semanage port -a -t http_port_t -p tcp "$PORT" 2>/dev/null || semanage port -m -t http_port_t -p tcp "$PORT" || true
    setsebool -P httpd_can_network_connect 1 >/dev/null 2>&1 || true
  fi
}

set_iptables_base(){
  iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -A INPUT -i lo -j ACCEPT
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport "$PORT" -j ACCEPT
  if [[ "$KEEP_SSH_FOR_CURRENT_IP" == "1" && -n "${SSH_CLIENT:-}" ]]; then
    CIP="${SSH_CLIENT%% *}"
    if [[ -n "$CIP" ]]; then
      for P in "${KEEP_CIP_PORTS[@]}"; do
        iptables -C INPUT -p tcp --dport "$P" -s "$CIP" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$P" -s "$CIP" -j ACCEPT
      done
    fi
  fi
  iptables -nL VALIDATEWL >/dev/null 2>&1 || iptables -N VALIDATEWL
  iptables -C INPUT -j VALIDATEWL 2>/dev/null || iptables -I INPUT 1 -j VALIDATEWL
  iptables -C INPUT -j DROP 2>/dev/null || iptables -A INPUT -j DROP
  service iptables save >/dev/null 2>&1 || true
  iptables-save > /etc/sysconfig/iptables >/dev/null 2>&1 || true
  systemctl enable iptables --now >/dev/null 2>&1 || true
}

restart_httpd(){ apachectl -t; systemctl restart httpd; }

self_test(){
  local ip; ip="$(server_ip)"
  echo "[INFO] Diag: https://${ip}:${PORT}/_diag.php"
  echo "[INFO] Self-test against https://${ip}:${PORT}/validate.php â€¦"
  if command -v curl >/dev/null 2>&1; then
    if curl -sk -X POST "https://${ip}:${PORT}/validate.php" \
      --data-urlencode 'user=admin' \
      --data-urlencode 'pass=ABC@xmenx1690!' \
      | grep -q "Login Validated for IP"; then
      echo "[OK] Portal accepted credentials and whitelisted your IP."
    else
      echo "[WARN] Self-test did not find success text. Body head:"
      curl -sk -X POST "https://${ip}:${PORT}/validate.php" \
        --data-urlencode 'user=admin' \
        --data-urlencode 'pass=ABC@xmenx1690!' \
        | sed -n '1,25p'
      echo "Tail log:"
      tail -n 40 "/var/log/httpd/validate-${PORT}-error.log" || true
    fi
  fi
}

summary(){
  local ip; ip="$(server_ip)"
  echo
  echo "[OK] Issabel dynportal installed."
  echo "Open: https://${ip}:${PORT}/validate.php"
  echo "Diag: https://${ip}:${PORT}/_diag.php"
  echo "User: ${ADMIN_USER}"
  echo "Pass: ${ADMIN_PASS}"
  [[ -n "${SSH_CLIENT:-}" ]] && echo "Protected IP: ${SSH_CLIENT%% *} on ports: ${KEEP_CIP_PORTS[*]}"
  echo "Logs: /var/log/httpd/validate-${PORT}-error.log"
}

main(){
  ensure_repos_ready
  install_packages
  detect_web_user
  set_servername
  set_ssl
  write_vhost
  write_app
  create_htpasswd
  write_helper
  set_sudoers
  set_selinux
  set_iptables_base
  restart_httpd

  if php -i 2>/dev/null | grep -i '^disable_functions' | grep -q exec; then
    echo "[WARN] PHP 'exec' is disabled in php.ini; enable it so validate.php can call sudo."
  fi

  self_test
  summary
}

main "$@"

