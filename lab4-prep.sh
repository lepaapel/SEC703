#!/usr/bin/env bash
set -euo pipefail


random_text() {
  local length="$1"
  local value

  set +o pipefail
  value="$(tr -dc 'a-z0-9' </dev/urandom | head -c "$length")"
  set -o pipefail

  printf '%s' "$value"
}

random_documentation_ip() {
  local prefixes=(192.0.2 198.51.100 203.0.113)
  local prefix="${prefixes[$RANDOM % ${#prefixes[@]}]}"
  local host_octet=$((1 + RANDOM % 254))

  printf '%s.%s' "$prefix" "$host_octet"
}

STATE_FILE="/root/.osa-lab4.state"
LAB_NAME=""
STATE_DNS_OVERRIDE_IP=""

if [[ -f "$STATE_FILE" ]]; then
  LAB_NAME="$(awk -F= '$1 == "LAB_NAME" {gsub(/"/, "", $2); print $2}' "$STATE_FILE")"
  STATE_DNS_OVERRIDE_IP="$(awk -F= '$1 == "DNS_OVERRIDE_IP" {gsub(/"/, "", $2); print $2}' "$STATE_FILE")"
fi

if [[ -z "$LAB_NAME" ]]; then
  LAB_NAME="svc-cache-$(random_text 10)"
fi

TARGET_USED_PERCENT="${TARGET_USED_PERCENT:-95}"
MIN_FREE_MB="${MIN_FREE_MB:-768}"
HOME_COUNT="${HOME_COUNT:-48}"
RECURRING_APPEND_MB="${RECURRING_APPEND_MB:-25}"
RECURRING_INTERVAL="${RECURRING_INTERVAL:-5min}"
DNS_OVERRIDE_HOSTNAME="${DNS_OVERRIDE_HOSTNAME:-schedule.kse.ua}"
DNS_OVERRIDE_IP="${DNS_OVERRIDE_IP:-${STATE_DNS_OVERRIDE_IP:-$(random_documentation_ip)}}"
ACCESS_LOG_LINES="${ACCESS_LOG_LINES:-1000}"

MARKER="/root/.${LAB_NAME}-installed"
MANIFEST="/root/${LAB_NAME}-manifest.txt"
LOG_FILE="/var/log/${LAB_NAME}-bootstrap.log"

RECURRING_SCRIPT="/usr/local/bin/.${LAB_NAME}-worker"
SERVICE_FILE="/etc/systemd/system/${LAB_NAME}.service"
TIMER_FILE="/etc/systemd/system/${LAB_NAME}.timer"
HOSTS_BACKUP="/etc/hosts.${LAB_NAME}.bak"
HOSTS_BEGIN="# ${LAB_NAME} resolver cache begin"
HOSTS_END="# ${LAB_NAME} resolver cache end"
ACCESS_LOG_DIR="/var/log/www"
ACCESS_LOG_FILE="${ACCESS_LOG_DIR}/access.log"

DECOY_HOME_DIRS=()

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root"
    exit 1
  fi
}

persist_state() {
  cat >"$STATE_FILE" <<EOF
LAB_NAME="$LAB_NAME"
DNS_OVERRIDE_IP="$DNS_OVERRIDE_IP"
EOF

  chmod 600 "$STATE_FILE"
}

make_thematic_path() {
  local base="$1"
  local themes=(
    "movies horror english classics 1980"
    "movies drama french festival archived"
    "movies sci-fi japanese remastered 2001"
    "games arcade 2000 saves backup"
    "games strategy turn-based maps europe"
    "games rpg classic mods texture-pack"
    "music jazz live sessions 1998"
    "music rock demos studio mix"
    "photos travel london raw winter"
    "photos family scanned albums 2005"
    "books fiction english drafts"
    "books history medieval notes"
    "projects python data reports"
    "projects web nginx cache"
    "courses linux week04 troubleshooting"
    "courses cloud aws sandbox"
    "archives finance invoices 2023"
    "archives mail exports old"
    "backups laptop documents partial"
    "backups phone media encrypted"
  )
  local selected="${themes[$RANDOM % ${#themes[@]}]}"
  local path="$base"
  local extra_depth=$((1 + RANDOM % 4))
  local segment

  for segment in $selected; do
    path="${path}/${segment}"
    mkdir -p "$path"
  done

  for _ in $(seq 1 "$extra_depth"); do
    path="${path}/$(random_text $((6 + RANDOM % 8)))"
    mkdir -p "$path"
  done

  echo "$path"
}

create_decoy_homes() {
  echo "[+] Creating decoy home directory tree"

  local first_names=(
    albert ada grace alan marie isaac nikola katherine richard dorothy
    james margaret edsger barbara linus tim dennis ken brian donald
    leslie hedy claude john radia brendan guido bjarne frances allen
    carol martin anita george betty david evelyn robert mary peter
  )
  local last_names=(
    einstein lovelace hopper turing curie newton tesla johnson feynman vaughan
    gosling hamilton dijkstra liskov torvalds berners-lee ritchie thompson kernighan knuth
    lamport lamarr shannon carmack perlman eich rossum stroustrup allen kay
    shaw fowler borgs boole holberton wheeler berezin noether jackson norvig
  )
  local description=(do not parse this file, it is a decoy for the lab exercise)
  local created=0
  local base
  local first
  local last
  local path
  local max_homes
  declare -A used_homes=()

  max_homes="$((${#first_names[@]} * ${#last_names[@]}))"
  if (( HOME_COUNT > max_homes )); then
    echo "HOME_COUNT cannot be larger than $max_homes"
    exit 1
  fi

  while (( created < HOME_COUNT )); do
    first="${first_names[$RANDOM % ${#first_names[@]}]}"
    last="${last_names[$RANDOM % ${#last_names[@]}]}"
    base="/home/${first}.${last}"

    if [[ -n "${used_homes[$base]:-}" ]]; then
      continue
    fi

    used_homes["$base"]=1
    DECOY_HOME_DIRS+=("$base")

    mkdir -p "$base"
    path="$(make_thematic_path "$base")"

    for _ in $(seq 1 $((3 + RANDOM % 12))); do
      echo "temporary lab data" >"${path}/$(random_text $((6 + RANDOM % 10))).txt"
    done

    created=$((created + 1))
  done
}

choose_large_payload_path() {
  local candidates=(/opt /var/tmp /var/log)

  candidates+=("${DECOY_HOME_DIRS[@]}")
  local base="${candidates[$RANDOM % ${#candidates[@]}]}"
  local path

  path="$(make_thematic_path "$base")"

  echo "${path}/.cache-db-$(random_text 12).bin"
}

create_large_payload() {
  local payload="$1"
  local total_mb
  local used_mb
  local free_mb
  local desired_used_mb
  local fill_mb
  local max_fill_mb

  total_mb="$(df -Pm / | awk 'NR==2 {print $2}')"
  used_mb="$(df -Pm / | awk 'NR==2 {print $3}')"
  free_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  desired_used_mb="$(( (total_mb * TARGET_USED_PERCENT) / 100 ))"
  fill_mb="$(( desired_used_mb - used_mb ))"
  max_fill_mb="$(( free_mb - MIN_FREE_MB ))"

  if (( max_fill_mb <= 0 )); then
    echo "Not enough free space to safely create the large payload"
    exit 1
  fi

  if (( fill_mb > max_fill_mb )); then
    fill_mb="$max_fill_mb"
  fi

  if (( fill_mb < 1 )); then
    fill_mb=1
  fi

  echo "[+] Payload size: ${fill_mb} MB" >&2

  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${fill_mb}M" "$payload"
  else
    dd if=/dev/zero of="$payload" bs=1M count="$fill_mb" status=progress
  fi

  chmod 600 "$payload"
  echo "$fill_mb"
}

install_recurring_systemd_incident() {
  local recurring_name="/opt/.cache-fragment-$(random_text 14).bin"

  echo "[+] Installing recurring systemd incident" >&2
  echo "[+] Fixed random recurring file: $recurring_name" >&2

  cat >"$RECURRING_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="$recurring_name"
APPEND_MB="$RECURRING_APPEND_MB"

mkdir -p "\$(dirname "\$TARGET_FILE")"

dd if=/dev/zero of="\$TARGET_FILE" bs=1M count="\$APPEND_MB" oflag=append conv=notrunc status=none
chmod 600 "\$TARGET_FILE"
EOF

  chmod 700 "$RECURRING_SCRIPT"

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=OSA lab disk cache refresh

[Service]
Type=oneshot
ExecStart=$RECURRING_SCRIPT
EOF

  cat >"$TIMER_FILE" <<EOF
[Unit]
Description=Run OSA lab disk cache refresh every $RECURRING_INTERVAL

[Timer]
OnBootSec=1min
OnUnitActiveSec=$RECURRING_INTERVAL
Unit=${LAB_NAME}.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload >&2
  systemctl enable --now "${LAB_NAME}.timer" >/dev/null

  echo "$recurring_name"
}

install_dns_override() {
  if grep -Fq "$HOSTS_BEGIN" /etc/hosts; then
    echo "[+] Local DNS override is already present" >&2
    return
  fi

  cp -p /etc/hosts "$HOSTS_BACKUP"

  cat >>/etc/hosts <<EOF

$HOSTS_BEGIN
$DNS_OVERRIDE_IP $DNS_OVERRIDE_HOSTNAME
$HOSTS_END
EOF
}

random_client_ip() {
  local networks=(10 172 192 198 203)
  local selected="${networks[$RANDOM % ${#networks[@]}]}"

  case "$selected" in
    10)
      printf '10.%d.%d.%d' "$((RANDOM % 256))" "$((RANDOM % 256))" "$((1 + RANDOM % 254))"
      ;;
    172)
      printf '172.%d.%d.%d' "$((16 + RANDOM % 16))" "$((RANDOM % 256))" "$((1 + RANDOM % 254))"
      ;;
    192)
      printf '192.168.%d.%d' "$((RANDOM % 256))" "$((1 + RANDOM % 254))"
      ;;
    198)
      printf '198.51.100.%d' "$((1 + RANDOM % 254))"
      ;;
    203)
      printf '203.0.113.%d' "$((1 + RANDOM % 254))"
      ;;
  esac
}

weighted_status() {
  local roll=$((1 + RANDOM % 100))

  if (( roll <= 58 )); then
    echo 200
  elif (( roll <= 70 )); then
    echo 301
  elif (( roll <= 78 )); then
    echo 302
  elif (( roll <= 84 )); then
    echo 304
  elif (( roll <= 89 )); then
    echo 400
  elif (( roll <= 93 )); then
    echo 404
  elif (( roll <= 95 )); then
    echo 403
  elif (( roll <= 97 )); then
    echo 500
  elif (( roll <= 99 )); then
    echo 502
  else
    echo 503
  fi
}

create_access_log_lab() {
  echo "[+] Creating restricted access log at $ACCESS_LOG_FILE" >&2

  local methods=(GET GET GET GET POST POST PUT DELETE HEAD)
  local paths=(
    /
    /login
    /logout
    /api/v1/users
    /api/v1/orders
    /api/v1/payments
    /api/v1/schedule
    /api/v1/schedule/today
    /api/v1/reports
    /assets/app.js
    /assets/main.css
    /assets/logo.png
    /health
    /admin
    /admin/login
    /docs
    /favicon.ico
    /robots.txt
    /search?q=linux
    /search?q=devops
    /wp-login.php
    /.env
  )
  local agents=(
    "Mozilla/5.0"
    "curl/8.5.0"
    "python-requests/2.31"
    "Go-http-client/1.1"
    "kube-probe/1.29"
    "ELB-HealthChecker/2.0"
  )
  local referers=(
    "-"
    "https://schedule.kse.ua/"
    "https://portal.kse.ua/"
    "https://google.com/"
    "https://github.com/"
  )
  local hot_clients=(
    198.51.100.77
    203.0.113.42
    192.168.10.15
    10.24.8.91
    172.20.31.8
  )
  local tmp_file
  local i
  local client_ip
  local method
  local path
  local status
  local bytes
  local timestamp
  local agent
  local referer
  local response_ms

  mkdir -p "$ACCESS_LOG_DIR"
  tmp_file="$(mktemp)"

  for i in $(seq 1 "$ACCESS_LOG_LINES"); do
    if (( RANDOM % 100 < 35 )); then
      client_ip="${hot_clients[$RANDOM % ${#hot_clients[@]}]}"
    else
      client_ip="$(random_client_ip)"
    fi

    method="${methods[$RANDOM % ${#methods[@]}]}"
    path="${paths[$RANDOM % ${#paths[@]}]}"
    status="$(weighted_status)"
    bytes="$((256 + RANDOM % 750000))"
    timestamp="$(date -u -d "$((ACCESS_LOG_LINES - i)) minutes ago" '+%d/%b/%Y:%H:%M:%S +0000')"
    agent="${agents[$RANDOM % ${#agents[@]}]}"
    referer="${referers[$RANDOM % ${#referers[@]}]}"
    response_ms="$((10 + RANDOM % 1900))"

    printf '%s - - [%s] "%s %s HTTP/1.1" %s %s "%s" "%s" rt=%sms\n' \
      "$client_ip" "$timestamp" "$method" "$path" "$status" "$bytes" "$referer" "$agent" "$response_ms" \
      >>"$tmp_file"
  done

  mv "$tmp_file" "$ACCESS_LOG_FILE"
  chown root:root "$ACCESS_LOG_DIR" "$ACCESS_LOG_FILE"
  chmod 755 "$ACCESS_LOG_DIR"
  chmod 600 "$ACCESS_LOG_FILE"
}

write_manifest() {
  local large_payload="$1"
  local large_payload_mb="$2"
  local recurring_file="$3"

  cat >"$MANIFEST" <<EOF
EOF

  {
    echo
    echo "Decoy home directories:"
    printf '%s\n' "${DECOY_HOME_DIRS[@]}"
  } >>"$MANIFEST"

  chmod 600 "$MANIFEST"
}

main() {
  require_root

  if [[ -f "$MARKER" ]]; then
    echo "Lab incident is already installed. See $MANIFEST"
    exit 0
  fi

  persist_state

  exec > >(tee -a "$LOG_FILE") 2>&1

  echo "[+] Starting $LAB_NAME bootstrap"
  create_decoy_homes

  large_payload="$(choose_large_payload_path)"
  large_payload_mb="$(create_large_payload "$large_payload")"
  recurring_file="$(install_recurring_systemd_incident)"
  install_dns_override
  create_access_log_lab

  write_manifest "$large_payload" "$large_payload_mb" "$recurring_file"
  touch "$MARKER"

  echo "[+] Done"
  echo "[+] Manifest: $MANIFEST"
  df -h /
}

main "$@"
