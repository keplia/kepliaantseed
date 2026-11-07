#!/usr/bin/env bash
# antseed-fleet — many independent Antseed gateways on one VPS.
#
# One command, interactive:
#   bash install.sh          (or: curl -fsSL <url> | bash)
#
# It asks for the Cloudflare API token and the domain, inspects the VPS, shows
# how many instances fit, asks how many to create, then builds them one by one.
# Every instance gets its own system user, data dir, wallets, database, ports,
# systemd units, Cloudflare tunnel and public hostname (api2, api3, api4, ...).
#
# Non-interactive (CI, cloud-init):
#   CF_API_TOKEN=... CF_DOMAIN=example.com COUNT=2 bash install.sh --yes
#
# Exit codes: 0 ok, 1 usage/validation, 2 cancelled, 3 failed mid-way.

set -Eeuo pipefail

VERSION="1.0.0"
PREFIX="${ANTSEED_FLEET_PREFIX:-antseed}"
STATE_DIR="/etc/${PREFIX}-fleet"
UNIT_DIR="/etc/systemd/system"
CLI_BIN="/opt/antseed/current/bin/antseed"
CLI_NODE_PATH="/opt/antseed/node/bin"
CF_API="https://api.cloudflare.com/client/v4"
INSTALL_SH="https://antseed.com/install.sh"

ASSUME_YES=0

# flags (also settable by environment)
while (( $# )); do
  case $1 in
    --token)   CF_API_TOKEN=$2; shift 2 ;;
    --domain)  CF_DOMAIN=$2; shift 2 ;;
    --count)   COUNT=$2; shift 2 ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --version) echo "antseed-fleet $VERSION"; exit 0 ;;
    --help|-h) printf '%s\n' "usage: install.sh [--token T] [--domain D] [--count N] [--yes]"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

MEM_PER_INSTANCE_MIB="${ANTSEED_MEM_PER_INSTANCE_MIB:-900}"
MEM_RESERVE_MIB="${ANTSEED_MEM_RESERVE_MIB:-1024}"
DISK_PER_INSTANCE_MIB="${ANTSEED_DISK_PER_INSTANCE_MIB:-400}"

# --------------------------------------------------------------- output

if [[ -t 1 ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'
  C_D=$'\033[2m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''; C_BOLD=''; C_0=''
fi

step() { printf '\n%s\n' "${C_B}${C_BOLD}▸ $*${C_0}"; }
info() { printf '%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '%s\n' "${C_G}  ✔${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}  !${C_0} $*" >&2; }
die() { # die "message" [exit-code]
  local code=1
  if (( $# >= 2 )) && [[ ${!#} =~ ^[0-9]+$ ]]; then
    code=${!#}
    set -- "${@:1:$(($# - 1))}"
  fi
  printf '%s\n' "${C_R}  ✘ $*${C_0}" >&2
  exit "$code"
}

# interactive only when we have a terminal to ask on. stdin is a pipe when the
# script is started with "curl ... | sudo bash", so /dev/tty is what matters.
have_tty() { ( exec 3<>/dev/tty ) 2>/dev/null; }

interactive() {
  [[ $ASSUME_YES -eq 0 ]] || return 1
  [[ -t 1 ]] || return 1
  have_tty
}

say() { # diagnostics; never fatal
  if [[ -t 2 ]] || [[ -w /dev/tty ]]; then printf '%s\n' "$*" >&2 || true; fi
}

ask() { # ask "prompt" [default] -> echoes the answer
  local prompt=$1 default=${2:-} answer=
  if [[ $ASSUME_YES -eq 0 ]] && have_tty; then
    if [[ -n $default ]]; then
      read -r -p "$prompt [$default]: " answer </dev/tty || true
      printf '%s' "${answer:-$default}"
    else
      read -r -p "$prompt: " answer </dev/tty || true
      printf '%s' "$answer"
    fi
  else
    printf '%s' "$default"
  fi
}

ask_secret() { # never echoed; reads from the terminal
  local prompt=$1 answer=
  if [[ $ASSUME_YES -eq 0 ]] && have_tty; then
    read -r -s -p "$prompt: " answer </dev/tty || true
    printf '\n' >/dev/tty
  elif [[ $ASSUME_YES -eq 0 && ! -t 0 && ! -p /dev/stdin ]]; then
    # stdin still has data (e.g. here-string); never block on an empty pipe
    read -r answer || true
  fi
  printf '%s' "$answer"
}

confirm() { # confirm "question" -> 0 yes, 1 no
  local q=$1 answer
  [[ $ASSUME_YES -eq 0 ]] || return 0
  have_tty || return 0
  read -r -p "$q [Y/n]: " answer </dev/tty || true
  case ${answer:-y} in [yY]|"") return 0 ;; *) return 1 ;; esac
}

trap 'die "failed at line $LINENO: $BASH_COMMAND" 3' ERR

# ---------------------------------------------------------- prerequisites

case "$(uname -s)" in
  Linux) ;;
  *) die "this script targets Linux with systemd (use WSL or a Linux VPS)" ;;
esac
command -v systemctl >/dev/null || die "systemd is required"
[[ $EUID -eq 0 ]] || die "run as root (sudo bash $0)"
[[ -f /etc/os-release ]] || die "unknown distribution"
command -v curl >/dev/null || die "curl is required"

ensure_cli() {
  if [[ -x $CLI_BIN ]]; then
    ok "Antseed CLI present"
    return 0
  fi
  info "Antseed CLI not found — installing the base gateway (Node.js + CLI)"
  curl -fsSL --proto '=https' --tlsv1.2 "$INSTALL_SH" | bash -s -- --public-url "http://127.0.0.1:8379" >/tmp/antseed-base-install.log 2>&1 || {
    tail -20 /tmp/antseed-base-install.log >&2
    die "base gateway install failed (log: /tmp/antseed-base-install.log)"
  }
  [[ -x $CLI_BIN ]] || die "installer finished but $CLI_BIN is missing"
  ok "Antseed CLI installed"
}

# ---------------------------------------------------------- cloudflare

cf() {
  local method=$1 path=$2 body=${3:-}
  if [[ -n $body ]]; then
    curl -fsS -m 60 -X "$method" "$CF_API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" -d "$body"
  else
    curl -fsS -m 60 -X "$method" "$CF_API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN"
  fi
}

cfj() {
  local expr=$1
  node -e '
let s = "";
process.stdin.on("data", d => s += d).on("end", () => {
  let j;
  try { j = JSON.parse(s); }
  catch (e) { console.error("bad JSON from Cloudflare"); process.exit(1); }
  if (j.success === false) { console.error("Cloudflare error:", JSON.stringify(j.errors)); process.exit(1); }
  const v = eval(process.argv[1]);
  process.stdout.write(v === undefined || v === null ? "" : String(v));
});' "$expr"
}

cf_verify() {
  [[ -n ${CF_API_TOKEN:-} ]] || die "no Cloudflare API token"
  local status
  status=$(cf GET /user/tokens/verify 2>/dev/null | cfj 'j.result.status' || true)
  [[ $status == active ]] || die "Cloudflare token is not active"
  ACCOUNT_ID=$(cf GET /accounts | cfj 'j.result[0].id')
  ACCOUNT_NAME=$(cf GET /accounts | cfj 'j.result[0].name')
  [[ -n $ACCOUNT_ID ]] || die "token cannot list accounts (needs Account Settings: Read)"
}

cf_zone_id() {
  local cur=$1 z
  while [[ $cur == *.* ]]; do
    z=$(cf GET "/zones?name=$cur" 2>/dev/null | cfj 'j.result[0]?.id || ""' || true)
    [[ -n $z ]] && { printf '%s' "$z"; return 0; }
    cur=${cur#*.}
  done
  return 1
}

zone_root() { # api3.example.com -> example.com
  local host=$1
  host=${host#*.}
  while [[ $host == *.* ]]; do
    if cf_zone_id "$host" >/dev/null 2>&1; then printf '%s' "$host"; return 0; fi
    host=${host#*.}
  done
  return 1
}

# ------------------------------------------------------------- resources

mem_total_mib() { awk '/MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo; }
mem_avail_mib() { awk '/MemAvailable/ { printf "%d", $2 / 1024 }' /proc/meminfo; }
disk_avail_mib() { df -Pm /var/lib | awk 'NR == 2 { print $4 }'; }

recommend_count() {
  local avail by_mem by_disk
  avail=$(mem_avail_mib)
  by_mem=$(( (avail - MEM_RESERVE_MIB) / MEM_PER_INSTANCE_MIB ))
  (( by_mem < 0 )) && by_mem=0
  by_disk=$(( $(disk_avail_mib) / DISK_PER_INSTANCE_MIB ))
  echo "$by_mem $by_disk $avail"
}

# ------------------------------------------------------------- instances

state_file() { echo "$STATE_DIR/$1.env"; }

instance_names() {
  local f
  for f in "$STATE_DIR"/*.env; do
    [[ -e $f ]] || continue
    basename "$f" .env
  done | sort -V
}

existing_instances() {
  local n
  while read -r n; do
    [[ -n $n ]] || continue
    ( . "$(state_file "$n")"; echo "$INSTANCE $HOST" )
  done <<<"$(instance_names)"
}

instance_exists() { [[ -f $(state_file "$1") ]]; }

next_index() {
  local i=1 used
  used=$(instance_names)
  while grep -qx "${PREFIX}${i}" <<<"$used"; do i=$((i + 1)); done
  echo "$i"
}

next_host_num() {
  existing_instances | awk '
    { n = $2; sub(/\..*/, "", n); gsub(/[^0-9]/, "", n); if (n != "" && n + 0 > m) m = n + 0 }
    END { print m + 1 }'
}

load_instance() {
  local f
  [[ -n ${1:-} ]] || die "instance name required"
  f=$(state_file "$1")
  [[ -f $f ]] || die "instance '$1' not found (see: antseed-fleet list)"
  . "$f"
}

as_instance() {
  local user=$1 home=$2
  shift 2
  runuser -u "$user" -- env HOME="$home" PATH="$CLI_NODE_PATH:/usr/bin:/bin" "$CLI_BIN" "$@"
}

port_busy() { # true when anything listens on (or connects from) that port
  ss -Hltnu 2>/dev/null |
    awk -v p="$1" '
      { n = split($4, a, /[:.]/); if (a[n] == p) f = 1
        n = split($5, b, /[:.]/); if (b[n] == p) f = 1 }
      END { exit f ? 0 : 1 }'
}

baseline_ports() {
  local unit="$UNIT_DIR/antseed-buyer.service" bport=""
  [[ -f $unit ]] || return 0
  bport=$(sed -n 's/.*buyer start --port \([0-9][0-9]*\).*/\1/p' "$unit" | head -1)
  echo "8379 ${bport:-8377}"
}

alloc_ports() {
  local gw=8379 buyer=8377 reserved base all
  reserved=$(existing_instances | awk '{ print $1 }' | while read -r n; do
    local f="$STATE_DIR/$n.env"
    [[ -f $f ]] && ( . "$f"; echo "$GW_PORT $BUYER_PORT" )
  done)
  base=$(baseline_ports)
  [[ -n $base ]] && reserved="$base
$reserved"
  all=$reserved

  while port_busy "$gw" || grep -qE "^$gw " <<<"$all" || grep -qxE "[0-9]+ $gw" <<<"$all"; do
    gw=$((gw + 1))
  done
  while port_busy "$buyer" || grep -qxE "[0-9]+ $buyer" <<<"$all" || [[ $buyer == "$gw" ]]; do
    buyer=$((buyer + 1))
  done
  echo "$gw $buyer"
}

wait_port() {
  local port=$1 tries=${2:-60} i
  for (( i = 0; i < tries; i++ )); do
    port_busy "$port" && return 0
    sleep 1
  done
  return 1
}

write_units() {
  local name=$1 user=$2 home=$3 gw=$4 buyer=$5

  cat >"$UNIT_DIR/$name-buyer.service" <<UNIT
[Unit]
Description=Antseed buyer ($name)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$CLI_BIN buyer start --port $buyer
Environment=ANTSEED_SUPERVISED=1
Environment=MALLOC_ARENA_MAX=2
Environment=MALLOC_MMAP_THRESHOLD_=131072
Environment=MALLOC_TRIM_THRESHOLD_=131072
User=$user
Group=$user
Environment=HOME=$home
Environment=PATH=$CLI_NODE_PATH:/usr/local/bin:/usr/bin:/bin
Restart=always
RestartSec=5
TimeoutStopSec=90
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$home
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
UNIT

  cat >"$UNIT_DIR/$name-gateway.service" <<UNIT
[Unit]
Description=Antseed API-key gateway ($name)
After=network-online.target $name-buyer.service
Wants=network-online.target $name-buyer.service

[Service]
EnvironmentFile=/etc/$name/gateway.env
ExecStart=$CLI_BIN tunnel start --no-buyer --provider cloudflare --buyer-port $buyer --gateway-port $gw
User=$user
Group=$user
Environment=HOME=$home
Environment=PATH=$CLI_NODE_PATH:/usr/local/bin:/usr/bin:/bin
Restart=always
RestartSec=5
TimeoutStopSec=90
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$home
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
UNIT
}

create_one() {
  local host=$1 idx user inst home gw_port buyer_port zone_id tunnel_id tunnel_name
  idx=""
  if [[ $host =~ ^api([0-9]+)\. ]]; then
    idx=${BASH_REMATCH[1]}
    instance_exists "${PREFIX}${idx}" && idx=""
  fi
  [[ -n $idx ]] || idx=$(next_index)
  user="${PREFIX}${idx}"
  inst=$user
  home="/var/lib/$user"

  info "creating $inst for $host"

  if ! id "$user" >/dev/null 2>&1; then
    useradd --system --home-dir "$home" --create-home --shell /usr/sbin/nologin "$user"
    ok "system user $user ($home)"
  else
    ok "system user $user already exists"
  fi
  install -d -o "$user" -g "$user" -m 700 "$home"

  read -r gw_port buyer_port <<<"$(alloc_ports)"
  ok "ports gateway=$gw_port buyer=$buyer_port"

  zone_id=$(cf_zone_id "$CF_DOMAIN") || die "zone lookup failed for $CF_DOMAIN"
  tunnel_name="$inst-gateway"
  tunnel_id=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel?name=$tunnel_name&is_deleted=false" 2>/dev/null |
    cfj 'j.result[0]?.id || ""' || true)
  if [[ -n $tunnel_id ]]; then
    ok "reusing tunnel $tunnel_name ($tunnel_id)"
  else
    tunnel_id=$(cf POST "/accounts/$ACCOUNT_ID/cfd_tunnel" \
      "{\"name\":\"$tunnel_name\",\"config_src\":\"cloudflare\"}" | cfj 'j.result.id')
    ok "tunnel $tunnel_name ($tunnel_id)"
  fi

  cf PUT "/accounts/$ACCOUNT_ID/cfd_tunnel/$tunnel_id/configurations" \
    "{\"config\":{\"ingress\":[{\"hostname\":\"$host\",\"service\":\"http://localhost:$gw_port\"},{\"service\":\"http_status:404\"}]}}" \
    >/dev/null
  ok "ingress $host -> http://localhost:$gw_port"

  local dns_name=$host dns_body rec_id
  [[ $host == *".$CF_DOMAIN" ]] && dns_name=${host%".$CF_DOMAIN"}
  rec_id=$(cf GET "/zones/$zone_id/dns_records?name=$host" | cfj 'j.result[0]?.id || ""')
  dns_body="{\"type\":\"CNAME\",\"name\":\"$dns_name\",\"content\":\"$tunnel_id.cfargotunnel.com\",\"proxied\":true,\"ttl\":1}"
  if [[ -n $rec_id ]]; then
    cf PUT "/zones/$zone_id/dns_records/$rec_id" "$dns_body" >/dev/null
    ok "DNS $host updated (CNAME -> tunnel)"
  else
    cf POST "/zones/$zone_id/dns_records" "$dns_body" >/dev/null
    ok "DNS $host created (CNAME -> tunnel)"
  fi

  local tunnel_token
  tunnel_token=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$tunnel_id/token" | cfj 'j.result')
  install -d -m 755 "/etc/$inst"
  (
    umask 077
    printf 'CLOUDFLARED_TUNNEL_TOKEN=%s\n' "$tunnel_token" >"/etc/$inst/gateway.env"
    printf 'ANTSEED_TUNNEL_PUBLIC_URL=https://%s\n' "$host" >>"/etc/$inst/gateway.env"
    printf 'ANTSEED_TRUST_CLOUDFLARE_HEADERS=1\n' >>"/etc/$inst/gateway.env"
  )
  chmod 600 "/etc/$inst/gateway.env"
  ok "env /etc/$inst/gateway.env (0600)"

  write_units "$inst" "$user" "$home" "$gw_port" "$buyer_port"
  systemctl daemon-reload
  ok "units $inst-buyer, $inst-gateway"

  systemctl enable --now "$inst-buyer.service" >/dev/null 2>&1
  if ! wait_port "$buyer_port" 60; then
    die "buyer did not open port $buyer_port (journalctl -u $inst-buyer)" 3
  fi
  if journalctl -u "$inst-buyer" --no-pager -n 60 2>/dev/null | grep -q 'already in use; reusing existing local proxy'; then
    die "port $buyer_port is owned by another process" 3
  fi
  ok "buyer listening on $buyer_port"

  local key_json key wallet
  key_json=$(as_instance "$user" "$home" gateway key create --label admin --json)
  key=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).apiKey)' "$key_json")
  wallet=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).identityAddress || "")' "$key_json")
  ok "API key created (label: admin)"

  systemctl enable --now "$inst-gateway.service" >/dev/null 2>&1
  wait_port "$gw_port" 90 || die "gateway did not open port $gw_port" 3
  ok "gateway listening on $gw_port"

  install -d -m 700 "$STATE_DIR"
  (
    umask 077
    {
      echo "INSTANCE=$inst"
      echo "USER=$user"
      echo "HOME_DIR=$home"
      echo "HOST=$host"
      echo "GW_PORT=$gw_port"
      echo "BUYER_PORT=$buyer_port"
      echo "TUNNEL_ID=$tunnel_id"
      echo "ZONE_ID=$zone_id"
      echo "API_KEY=$key"
      echo "WALLET=$wallet"
      echo "CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$(state_file "$inst")"
  )

  local i up=0 code
  for (( i = 0; i < 45; i++ )); do
    if journalctl -u "$inst-gateway" --no-pager -n 200 2>/dev/null |
      grep -qE 'Public HTTPS tunnel is running|Registered tunnel connection'; then
      up=1; break
    fi
    sleep 2
  done
  (( up )) || warn "tunnel still connecting"

  code=$(curl -sS -m 45 -o /dev/null -w '%{http_code}' "https://$host/v1/models" \
    -H "Authorization: Bearer $key" 2>/dev/null || true)
  [[ $code == 200 ]] && ok "https://$host/v1/models -> 200" ||
    warn "https://$host/v1/models -> ${code:-no response} (DNS may still propagate)"

  local link
  link=$(as_instance "$user" "$home" gateway console-link 2>/dev/null | grep -oE 'https://[^ ]+' | head -1 || true)

  printf '%s\n' "${C_G}${C_BOLD}  $inst is up${C_0}"
  printf '    %-10s %s\n' "Base URL" "https://$host/v1"
  printf '    %-10s %s\n' "Console" "https://$host/console"
  printf '    %-10s %s\n' "API key" "$key"
  printf '    %-10s %s\n' "Wallet" "${wallet:-(see console)}"
  printf '    %-10s %s\n' "Setup" "${link:-(run: antseed-fleet link $inst)}"
  printf '%s\n' "${C_D}    The API key is shown once. Store it now.${C_0}"
}

# ============================================================ main flow

step "Antseed fleet installer $VERSION"

step "1/4 · Cloudflare API token"
if [[ -z ${CF_API_TOKEN:-} ]]; then
  cat <<'TXT' >&2

  Create a scoped Cloudflare API token:
    https://dash.cloudflare.com/profile/api-tokens
    (Create Token -> Create Custom Token)

    Account | Cloudflare Tunnel | Edit
    Account | Account Settings  | Read
    Zone    | DNS               | Edit
    Zone    | Zone              | Read

    Account Resources: your account
    Zone Resources:    your zone
TXT
  if [[ $ASSUME_YES -eq 0 ]] && ! have_tty; then
    die "no terminal to type into. Run it in an interactive shell, or pass the value:
  curl -fsSL https://raw.githubusercontent.com/keplia/kepliaantseed/main/get.sh |
    sudo bash -s -- --token cf_xxx --domain example.com" 1
  fi
  while [[ -z ${CF_API_TOKEN:-} ]]; do
    CF_API_TOKEN=$(ask_secret "  Paste the Cloudflare API token")
    [[ -n $CF_API_TOKEN ]] || warn "token is empty - paste the cfut_... / cf_... value"
  done
fi
export CF_API_TOKEN

info "checking the token"
cf_verify
ok "account: $ACCOUNT_NAME"

step "2/4 · Domain"
if [[ -z ${CF_DOMAIN:-} ]]; then
  local_first=$(existing_instances | awk 'NR==1 { print $2 }')
  guess=""
  if [[ -n $local_first ]]; then guess=${local_first#*.}; fi
  if [[ -z $guess ]]; then
    guess=$(cf GET "/zones" 2>/dev/null | cfj '((j.result||[]).length===1 ? j.result[0].name : "")' || true)
  fi
  if [[ $ASSUME_YES -eq 0 ]] && ! have_tty; then
    die "no terminal to ask for the domain. Pass --domain example.com" 1
  fi
  while [[ -z ${CF_DOMAIN:-} ]]; do
    CF_DOMAIN=$(ask "  Domain to create gateways under (e.g. example.com)" "${guess:-}")
    [[ -n ${CF_DOMAIN:-} ]] && break
    if [[ -n ${guess:-} ]]; then CF_DOMAIN=$guess; break; fi
    warn "domain is required"
  done
fi
[[ -n ${CF_DOMAIN:-} ]] || die "no domain given"
# accept https://api.example.com/ or example.com and keep the zone part
CF_DOMAIN=${CF_DOMAIN#http://}; CF_DOMAIN=${CF_DOMAIN#https://}
CF_DOMAIN=${CF_DOMAIN%%/*}
if ! cf_zone_id "$CF_DOMAIN" >/dev/null; then
  trimmed=${CF_DOMAIN#*.}
  if cf_zone_id "$trimmed" >/dev/null; then CF_DOMAIN=$trimmed; fi
fi
export CF_DOMAIN
cf_zone_id "$CF_DOMAIN" >/dev/null || die "zone '$CF_DOMAIN' not found on this Cloudflare account"
ok "zone: $CF_DOMAIN  (hosts will be apiN.$CF_DOMAIN)"

step "3/4 · This VPS"
ensure_cli
read -r rec by_disk avail <<<"$(recommend_count)"
used=$(existing_instances | wc -l)

printf '    %-24s %s\n' "CPUs" "$(nproc)"
printf '    %-24s %s MiB\n' "RAM available" "$avail"
printf '    %-24s %s MiB\n' "Disk free" "$(disk_avail_mib)"
printf '    %-24s %s\n' "Instances already here" "$used"
printf '    %-24s %s MiB per instance\n' "Memory budget" "$MEM_PER_INSTANCE_MIB"
echo
printf '%s\n' "${C_D}    Sizing: 2 GB→1   4 GB→3   8 GB→7   16 GB→15   32 GB→33${C_0}"
if (( used > 0 )); then
  echo
  printf '    %-12s %s\n' "NAME" "HOST"
  existing_instances | while read -r n h; do printf '    %-12s %s\n' "$n" "$h"; done
fi
echo

if (( rec == 0 )); then
  warn "no room for another instance right now"
  count=0
else
  ok "recommended now: ${C_BOLD}$rec${C_0} more instance(s)   (disk allows $by_disk)"
  count=${COUNT:-}
  if [[ -z $count ]]; then
    while true; do
      count=$(ask "  How many instances do you want" "$rec")
      [[ $count =~ ^[0-9]+$ ]] || {
        warn "enter a number"
        if [[ ${COUNT:-} != "" && ! $count =~ ^[0-9]+$ ]]; then die "COUNT must be numeric" 1; fi
        continue
      }
      (( count > rec )) && {
        warn "$count is above the recommendation ($rec) — the VPS may run out of memory"
        confirm "  Continue anyway?" || { count=""; continue; }
      }
      (( count > 0 )) && break
      interactive || { count=0; break; }
    done
  fi
fi

(( count > 0 )) || { warn "nothing to do"; exit 0; }

step "4/4 · Creating $count instance(s)"
start_num=$(next_host_num)
hosts=()
for (( i = 0; i < count; i++ )); do
  hosts+=("api$((start_num + i)).$CF_DOMAIN")
done
printf '    %s\n' "${hosts[@]}"
echo
confirm "  Proceed?" || { warn "cancelled"; exit 2; }

created=0
for h in "${hosts[@]}"; do
  create_one "$h" || die "failed while creating $h (instances created so far: $created)" 3
  created=$((created + 1))
  echo
done

step "Done — $created instance(s) created"
printf '    %-12s %s\n' "NAME" "BASE URL"
existing_instances | while read -r n h; do printf '    %-12s https://%s/v1\n' "$n" "$h"; done
echo
info "manage with: antseed-fleet list | status | link NAME | logs NAME -f | remove NAME"
info "API keys are shown once above — save them now"
