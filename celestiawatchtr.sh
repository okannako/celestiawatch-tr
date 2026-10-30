#!/usr/bin/env bash
# =====================================================================
#  celestiawatch - Celestia Validator + Fibre kontrol ve Telegram uyarı aracı
#  https://github.com/okannako
#
#  GÜVENLİK İLKELERİ
#   - Sadece OKUR. Node ayarlarını değiştirmez, servisleri durdurmaz/başlatmaz.
#   - Zincire işlem (tx) göndermez, cüzdan/anahtar komutu çalıştırmaz.
#   - Hiçbir port açmaz. Sadece 127.0.0.1 RPC'yi okur ve Telegram'a mesaj yollar.
#   - Uyarı servisi root DEĞİL, ayrı ve yetkisiz "celestiawatch" kullanıcısıyla çalışır.
#     Bu kullanıcı /root ve /home klasörlerini göremez (anahtarlarınıza erişemez).
#
#  KOMUTLAR
#   sudo ./celestiawatch.sh install     Kurulum (soru sorar, servis + zamanlayıcı kurar)
#   sudo celestiawatch uninstall        Tamamen kaldırır
#   sudo celestiawatch doctor           Ayrıntılı tek seferlik kontrol raporu (ekrana)
#   celestiawatch status                Anlık durum özeti (ekrana)
#   sudo celestiawatch test             Telegram'a deneme mesajı yollar
#   celestiawatch watch                 Servisin dakikada bir çalıştırdığı kontrol
# =====================================================================
set -u
VERSION="1.0.0"
CONFIG_FILE="${CELESTIAWATCH_CONFIG:-/etc/celestiawatch/config.env}"
STATE_DIR="${STATE_DIRECTORY:-/var/lib/celestiawatch}"

# ---------- Varsayılan ayarlar (config.env bunları egale eder) ----------
RPC="http://127.0.0.1:26657"
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""
NODE_LABEL="validator"          # Mesajlarda görünen isim. IP veya şehir yazmayın.
APP_SERVICE="celestia-appd"
FIBRE_SERVICE="fibre"           # Fibre yoksa boş bırakın: FIBRE_SERVICE=""
BRIDGE_SERVICE=""               # Bridge varsa: BRIDGE_SERVICE="celestia-bridge"
FIBRE_PORT=7980
DISK_PATHS="/"                  # Birden fazla: DISK_PATHS="/ /data"
DISK_ALERT_PERCENT=85
MIN_PEERS=3
MISSED_ALERT=5                  # Bir kontrolde bu kadar blok kaçırılırsa uyar
STALL_MINUTES=3                 # Blok yüksekliği bu kadar dakika ilerlemezse uyar
REMIND_MINUTES=60               # Devam eden sorunları bu aralıkla hatırlat
DAILY_REPORT_HOUR=""            # Örn. 9 -> her gün 09:00'dan sonra bir durum özeti
MAX_BLOCKS_PER_RUN=50
DRY_RUN=0                       # 1 ise mesajları yollamaz, ekrana yazar

if [ -r "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

SENSITIVE_PORTS="9090 26669 26657 26658 1317"

# ---------- Yardımcılar ----------
need() { command -v "$1" >/dev/null 2>&1; }
rpc() { curl -s --max-time 5 "$RPC/$1" 2>/dev/null; }
now() { date +%s; }

send_tg() {
  local text="[$NODE_LABEL] $1"
  if [ "$DRY_RUN" = "1" ] || [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    printf '%s\n' "$text"
    return 0
  fi
  # Token komut satırında görünmesin diye adres curl'e stdin'den verilir.
  local code
  code=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_TOKEN" |
    curl -s --max-time 10 -o /dev/null -w '%{http_code}' -K - \
      --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
      --data-urlencode "text=$text" \
      --data-urlencode "disable_web_page_preview=true")
  if [ "$code" != "200" ]; then
    case "$code" in
      000) echo "Telegram'a bağlanılamadı (internet/DNS sorunu)." >&2 ;;
      401|404) echo "Telegram HTTP $code: bot token hatalı." >&2 ;;
      400|403) echo "Telegram HTTP $code: Chat ID hatalı veya bota henüz /start yazılmamış." >&2 ;;
      *) echo "Telegram HTTP $code: mesaj gönderilemedi." >&2 ;;
    esac
    return 1
  fi
}

service_exists() { [ -n "$1" ] && systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q .; }
# Adında verilen kelime geçen ve etkin (enabled) ya da çalışan ilk servisi bulur
find_service() {
  local u
  for u in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -i "$1" | sed 's/\.service$//'); do
    if systemctl is-enabled --quiet "$u" 2>/dev/null || systemctl is-active --quiet "$u" 2>/dev/null; then echo "$u"; return; fi
  done
}
service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# Hassas portlardan 127.0.0.1 dışında dinleyen var mı?
exposed_ports() {
  need ss || return 0
  ss -Hltn 2>/dev/null | awk '{print $4}' | while read -r a; do
    local port="${a##*:}" host="${a%:*}"
    case " $SENSITIVE_PORTS " in *" $port "*) ;; *) continue ;; esac
    case "$host" in 127.*|"[::1]"|"[::ffff:127."*|localhost) continue ;; esac
    echo "$port"
  done | sort -u | tr '\n' ' ' | sed 's/ $//'
}

port_listening() { need ss && ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }

disk_usage() { df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'; }

# ---------- Ortak veri toplama ----------
collect() {
  STATUS_JSON=$(rpc status)
  RPC_OK=0; HEIGHT=""; CATCHING=""; NETWORK=""; VAL_ADDR=""; VP=""; PEERS=""; APPV=""
  if [ -n "$STATUS_JSON" ] && echo "$STATUS_JSON" | jq -e .result >/dev/null 2>&1; then
    RPC_OK=1
    HEIGHT=$(echo "$STATUS_JSON" | jq -r .result.sync_info.latest_block_height)
    CATCHING=$(echo "$STATUS_JSON" | jq -r .result.sync_info.catching_up)
    NETWORK=$(echo "$STATUS_JSON" | jq -r .result.node_info.network)
    VAL_ADDR=$(echo "$STATUS_JSON" | jq -r .result.validator_info.address)
    VP=$(echo "$STATUS_JSON" | jq -r .result.validator_info.voting_power)
    PEERS=$(rpc net_info | jq -r '.result.n_peers // empty' 2>/dev/null)
    APPV=$(rpc abci_info | jq -r '.result.response.app_version // empty' 2>/dev/null)
  fi
}

# Son kontrol edilen bloktan bu yana kaç blok kaçırıldı (sadece okuma, RPC /commit)
count_missed() {
  MISSED=0; CHECKED=0
  [ "$RPC_OK" = 1 ] && [ "${VP:-0}" != "0" ] || return 0
  local last start end h n
  last=$(cat "$STATE_DIR/last_height" 2>/dev/null || echo 0)
  end=$((HEIGHT - 1))
  start=$((last + 1))
  [ $((end - start + 1)) -gt "$MAX_BLOCKS_PER_RUN" ] && start=$((end - MAX_BLOCKS_PER_RUN + 1))
  for ((h = start; h <= end; h++)); do
    n=$(rpc "commit?height=$h" | jq -r --arg a "$VAL_ADDR" \
      '[.result.signed_header.commit.signatures[]? | select(.validator_address==$a and (.block_id_flag==2 or .block_id_flag==3))] | length' 2>/dev/null)
    [ -z "$n" ] && continue
    CHECKED=$((CHECKED + 1))
    [ "$n" = "0" ] && MISSED=$((MISSED + 1))
  done
  [ "$end" -gt 0 ] && echo "$end" > "$STATE_DIR/last_height"
}

summary_text() {
  local s="📊 Durum"$'\n'
  if [ "$RPC_OK" = 1 ]; then
    local sync="evet"; [ "$CATCHING" = "true" ] && sync="HAYIR (yakalıyor)"
    local set="aktif sette"; [ "${VP:-0}" = "0" ] && set="aktif sette DEĞİL"
    s+="Ağ: $NETWORK | Blok: $HEIGHT | Senkron: $sync"$'\n'
    s+="Peer: ${PEERS:-?} | Oy gücü: ${VP:-?} ($set) | app v${APPV:-?}"$'\n'
  else
    s+="RPC yanıt vermiyor ($RPC)"$'\n'
  fi
  for svc in "$APP_SERVICE" "$FIBRE_SERVICE" "$BRIDGE_SERVICE"; do
    service_exists "$svc" || continue
    if service_active "$svc"; then s+="$svc: çalışıyor"; else s+="$svc: ÇALIŞMIYOR"; fi
    if [ "$svc" = "$FIBRE_SERVICE" ]; then
      if port_listening "$FIBRE_PORT"; then s+=" ($FIBRE_PORT dinleniyor)"; else s+=" ($FIBRE_PORT DİNLENMİYOR)"; fi
    fi
    s+=$'\n'
  done
  for p in $DISK_PATHS; do s+="Disk $p: %$(disk_usage "$p")"$'\n'; done
  local ex; ex=$(exposed_ports)
  if [ -n "$ex" ]; then s+="⚠️ Dışarı açık hassas port: $ex"$'\n'; else s+="Hassas portlar: kapalı (sadece 127.0.0.1)"$'\n'; fi
  printf '%s' "$s"
}

# ---------- watch: servis tarafından dakikada bir çalışır ----------
cmd_watch() {
  if [ "$(id -u)" = "0" ] && [ "${CELESTIAWATCH_ALLOW_ROOT:-0}" != "1" ]; then
    echo "watch, servis tarafından celestiawatch kullanıcısıyla çalıştırılır. Elle bakmak için: celestiawatch status"
    exit 1
  fi
  mkdir -p "$STATE_DIR" || exit 1
  exec 9>"$STATE_DIR/lock"; flock -n 9 || exit 0

  declare -A NOW=() PREV=()
  issue() { NOW["$1"]="$2"; }

  if [ -f "$STATE_DIR/alerts" ]; then
    while IFS='|' read -r k m; do [ -n "$k" ] && PREV["$k"]="$m"; done < "$STATE_DIR/alerts"
  fi

  collect

  if [ "$RPC_OK" != 1 ]; then
    issue rpc "Node RPC yanıt vermiyor. celestia-appd çalışıyor mu?"
    # RPC yokken zincir kontrolleri yapılamaz; önceki sorunlar "düzeldi" sayılmasın.
    for k in sync stall peers inactive missed; do
      [ -n "${PREV[$k]+x}" ] && issue "$k" "${PREV[$k]}"
    done
  else
    [ "$CATCHING" = "true" ] && issue sync "Node senkron değil (catching_up: true). Blok: $HEIGHT"

    # Blok ilerliyor mu?
    local lh lt
    read -r lh lt 2>/dev/null < "$STATE_DIR/height_seen" || { lh=0; lt=$(now); }
    if [ "$HEIGHT" != "$lh" ]; then
      echo "$HEIGHT $(now)" > "$STATE_DIR/height_seen"
    elif [ $(( $(now) - lt )) -ge $((STALL_MINUTES * 60)) ]; then
      issue stall "Blok yüksekliği $STALL_MINUTES dakikadır ilerlemiyor (blok $HEIGHT)."
    fi

    [ -n "$PEERS" ] && [ "$PEERS" -lt "$MIN_PEERS" ] && issue peers "Peer sayısı düşük: $PEERS"

    # Aktif setten düşme (jail veya unbond)
    local was_active; was_active=$(cat "$STATE_DIR/was_active" 2>/dev/null || echo "")
    if [ "${VP:-0}" = "0" ]; then
      [ "$was_active" = "1" ] && issue inactive "Validator aktif setten DÜŞTÜ (oy gücü 0). Jail olmuş olabilir."
      [ "$was_active" = "1" ] || echo 0 > "$STATE_DIR/was_active"
    else
      echo 1 > "$STATE_DIR/was_active"
    fi

    count_missed
    if [ "$MISSED" -ge "$MISSED_ALERT" ]; then
      issue missed "Son kontrolde $CHECKED bloktan $MISSED tanesi kaçırıldı."
    elif [ "$MISSED" -gt 0 ] && [ -f "$STATE_DIR/alerts" ] && grep -q '^missed|' "$STATE_DIR/alerts"; then
      issue missed "$(grep '^missed|' "$STATE_DIR/alerts" | cut -d'|' -f2-)"
    fi
  fi

  for svc in "$APP_SERVICE" "$FIBRE_SERVICE" "$BRIDGE_SERVICE"; do
    service_exists "$svc" || continue
    service_active "$svc" || issue "svc_$svc" "$svc servisi çalışmıyor."
  done
  if service_exists "$FIBRE_SERVICE" && service_active "$FIBRE_SERVICE" && ! port_listening "$FIBRE_PORT"; then
    issue fibre_port "Fibre çalışıyor ama $FIBRE_PORT portunu dinlemiyor."
  fi

  local ex; ex=$(exposed_ports)
  [ -n "$ex" ] && issue exposed "Hassas port(lar) dışarıya açık: $ex. Bunlar sadece 127.0.0.1'de dinlemeli."

  local i=0
  for p in $DISK_PATHS; do
    i=$((i + 1))
    local u; u=$(disk_usage "$p")
    [ -n "$u" ] && [ "$u" -ge "$DISK_ALERT_PERCENT" ] && issue "disk$i" "Disk $p doluluk %$u."
  done

  if need timedatectl; then
    [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "no" ] && issue ntp "Sunucu saati senkron değil (NTP)."
  fi

  # --- Yeni / düzelen sorunları bildir ---
  local msg="" k
  for k in "${!NOW[@]}"; do [ -z "${PREV[$k]+x}" ] && msg+="🔴 ${NOW[$k]}"$'\n'; done
  for k in "${!PREV[@]}"; do [ -z "${NOW[$k]+x}" ] && msg+="🟢 Düzeldi: ${PREV[$k]}"$'\n'; done

  local sent_ok=1
  if [ -n "$msg" ]; then
    send_tg "$msg" || sent_ok=0
    [ "$sent_ok" = 1 ] && now > "$STATE_DIR/last_remind"
  elif [ "${#NOW[@]}" -gt 0 ]; then
    local lr; lr=$(cat "$STATE_DIR/last_remind" 2>/dev/null || echo 0)
    if [ $(( $(now) - lr )) -ge $((REMIND_MINUTES * 60)) ]; then
      local r="⏰ Devam eden sorunlar:"$'\n'
      for k in "${!NOW[@]}"; do r+="🔴 ${NOW[$k]}"$'\n'; done
      send_tg "$r" && now > "$STATE_DIR/last_remind"
    fi
  fi
  # Mesaj gidemediyse durumu kaydetme; bir sonraki kontrolde tekrar dener.
  if [ "$sent_ok" = 1 ]; then
    : > "$STATE_DIR/alerts.tmp"
    for k in "${!NOW[@]}"; do printf '%s|%s\n' "$k" "${NOW[$k]//|/ }" >> "$STATE_DIR/alerts.tmp"; done
    mv "$STATE_DIR/alerts.tmp" "$STATE_DIR/alerts"
  fi

  # --- Günlük özet ---
  if [ -n "$DAILY_REPORT_HOUR" ] && [ "$(date +%-H)" -ge "$DAILY_REPORT_HOUR" ]; then
    local today; today=$(date +%F)
    if [ "$(cat "$STATE_DIR/last_daily" 2>/dev/null)" != "$today" ]; then
      send_tg "$(summary_text)" && echo "$today" > "$STATE_DIR/last_daily"
    fi
  fi
  return 0
}

# ---------- status: ekrana anlık özet ----------
cmd_status() { collect; summary_text; }

# ---------- doctor: ayrıntılı tek seferlik rapor ----------
ok()   { printf '  \e[32m✔\e[0m %s\n' "$1"; }
bad()  { printf '  \e[31m✘\e[0m %s\n' "$1"; }
warn() { printf '  \e[33m!\e[0m %s\n' "$1"; }
info() { printf '  - %s\n' "$1"; }

cmd_doctor() {
  echo; echo "celestiawatch doctor v$VERSION  (sadece okur, hiçbir şeyi değiştirmez)"; echo
  collect

  echo "Node"
  if [ "$RPC_OK" = 1 ]; then
    ok "RPC yanıt veriyor ($RPC)"
    info "Ağ: $NETWORK | Blok: $HEIGHT | Peer: ${PEERS:-?}"
    [ "$CATCHING" = "false" ] && ok "Senkron" || bad "Senkron değil (catching_up: $CATCHING)"
    if [ "${APPV:-0}" -ge 10 ] 2>/dev/null; then ok "app_version $APPV (Fibre destekli)"; else warn "app_version ${APPV:-?} (Fibre için 10+ gerekli)"; fi
    [ "${VP:-0}" != "0" ] && ok "Aktif sette, oy gücü $VP" || warn "Oy gücü 0 (aktif sette değil veya validator değil)"
  else
    bad "RPC yanıt vermiyor ($RPC)"
  fi

  echo; echo "Servisler"
  for svc in "$APP_SERVICE" "$FIBRE_SERVICE" "$BRIDGE_SERVICE"; do
    [ -z "$svc" ] && continue
    if ! service_exists "$svc"; then info "$svc: kurulu değil"; continue; fi
    service_active "$svc" && ok "$svc çalışıyor" || bad "$svc çalışmıyor"
  done

  echo; echo "Sürümler"
  local appd_bin; appd_bin=$(command -v celestia-appd || ls /root/go/bin/celestia-appd 2>/dev/null || true)
  local cur=""
  if [ -n "$appd_bin" ]; then cur=$("$appd_bin" version 2>/dev/null | head -1); info "celestia-appd: ${cur:-?}"; else info "celestia-appd bulunamadı"; fi
  need fibre && info "fibre: $(fibre version 2>/dev/null | head -1)"
  local latest="" filter='^v[0-9]+\.[0-9]+\.[0-9]+$'
  case "$NETWORK" in mocha*) filter='^v[0-9]+\.[0-9]+\.[0-9]+-mocha$' ;; esac
  latest=$(curl -s --max-time 10 -H "User-Agent: celestiawatch" "https://api.github.com/repos/celestiaorg/celestia-app/releases?per_page=60" |
    jq -r --arg f "$filter" '[.[] | select(.draft==false) | .tag_name | select(test($f))] | sort_by(ltrimstr("v") | split("-")[0] | split(".") | map(tonumber)) | last // empty' 2>/dev/null)
  if [ -n "$latest" ]; then
    if [ "v${cur#v}" = "$latest" ]; then ok "En güncel sürüm kullanılıyor ($latest)"; else warn "Son yayınlanan sürüm: $latest (sizde: ${cur:-?})"; fi
  else
    info "Son sürüm bilgisi alınamadı"
  fi

  if ! service_exists "$FIBRE_SERVICE"; then
    local fs; fs=$(find_service fibre)
    if [ -n "$fs" ]; then
      echo; echo "Fibre"
      warn "Fibre servisi '$fs' adıyla bulundu ama ayarlarda kayıtlı değil."
      info "Düzeltmek için: sudo sed -i 's/^FIBRE_SERVICE=.*/FIBRE_SERVICE=\"$fs\"/' $CONFIG_FILE"
    fi
  fi
  if service_exists "$FIBRE_SERVICE"; then
    echo; echo "Fibre"
    port_listening "$FIBRE_PORT" && ok "$FIBRE_PORT portu dinleniyor" || bad "$FIBRE_PORT portu dinlenmiyor"
    if [ -n "$appd_bin" ]; then
      local cons reg host
      cons=$("$appd_bin" comet show-address 2>/dev/null)
      reg=$("$appd_bin" query valaddr provider "$cons" --node "tcp://${RPC#*://}" -o json 2>/dev/null)
      host=$(echo "$reg" | grep -oE '[A-Za-z0-9.-]+:[0-9]+' | head -1)
      if [ -n "$host" ]; then
        ok "Zincirde kayıtlı Fibre adresi: $(echo "$host" | sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+\.[0-9]+/\1.*.*/')"
        local h="${host%:*}" ips resolved
        ips=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
        resolved=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u)
        [ -z "$resolved" ] && resolved="$h"
        if echo "$resolved" | grep -qxF -f <(echo "$ips"); then ok "Kayıtlı adres bu sunucuyu gösteriyor"; else warn "Kayıtlı adres bu sunucunun IP'leriyle eşleşmiyor (NAT/alan adı kullanıyorsanız normal olabilir)"; fi
        [ "${host##*:}" = "$FIBRE_PORT" ] || warn "Kayıtlı port ($FIBRE_PORT değil): ${host##*:}"
      else
        warn "Zincirde Fibre adresi bulunamadı. 'celestia-appd tx valaddr set-host' yapıldı mı?"
      fi
    fi
    info "Dışarıdan erişimi BAŞKA bir bilgisayardan deneyin: nc -vz SUNUCU_IP $FIBRE_PORT"
  fi

  echo; echo "Güvenlik"
  local ex; ex=$(exposed_ports)
  if ! need ss; then warn "ss komutu yok, port kontrolü yapılamadı (sudo apt install iproute2)"
  elif [ -n "$ex" ]; then bad "Dışarıya açık hassas port: $ex (sadece 127.0.0.1'de dinlemeli)"; else ok "9090 / 26669 / 26657 / 26658 / 1317 dışarı kapalı"; fi
  if need timedatectl; then
    [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] && ok "Saat senkron (NTP)" || warn "Saat senkron değil (NTP)"
  fi
  if need sysctl; then
    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] && ok "bbr aktif" || warn "bbr aktif değil"
  fi

  echo; echo "Disk"
  for p in $DISK_PATHS; do
    local u; u=$(disk_usage "$p")
    if [ -n "$u" ] && [ "$u" -ge "$DISK_ALERT_PERCENT" ]; then bad "$p %$u dolu"; else ok "$p %${u:-?} dolu"; fi
  done
  echo
}

# ---------- test ----------
cmd_test() {
  collect
  if send_tg "✅ celestiawatch kuruldu ve çalışıyor."$'\n'"$(summary_text)"; then echo "Deneme mesajı gönderildi."; else echo "Mesaj gönderilemedi. Token ve Chat ID'yi kontrol edin."; exit 1; fi
}

# ---------- install / uninstall ----------
cmd_install() {
  [ "$(id -u)" = "0" ] || { echo "Kurulum için: sudo ./celestiawatch.sh install"; exit 1; }
  echo "celestiawatch kurulumu. Bu araç node ayarlarınıza dokunmaz, sadece okur."
  local missing=""
  for c in curl jq ss flock systemctl; do need "$c" || missing+=" $c"; done
  if [ -n "$missing" ]; then
    echo "Eksik paketler kuruluyor:$missing"
    apt-get update -qq && apt-get install -y -qq curl jq iproute2 util-linux >/dev/null
  fi

  id celestiawatch >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin celestiawatch
  install -m 755 "$0" /usr/local/bin/celestiawatch
  mkdir -p /etc/celestiawatch

  if [ ! -f /etc/celestiawatch/config.env ]; then
    local tok chat label fib br disks
    echo; echo "Telegram bot token (@BotFather'dan alınır):"; read -r tok
    echo "Telegram Chat ID (@userinfobot size söyler):"; read -r chat
    echo "Mesajlarda görünecek isim (IP veya şehir yazmayın) [validator]:"; read -r label
    label=${label:-validator}
    fib=$(find_service fibre)
    br=$(find_service bridge)
    disks="/"; [ -d /data ] && [ "$(df -P /data | awk 'NR==2{print $6}')" != "/" ] && disks="/ /data"
    umask 027
    cat > /etc/celestiawatch/config.env <<EOF
# celestiawatch ayarları. Değiştirdikten sonra ekstra bir şey yapmanız gerekmez.
TELEGRAM_TOKEN="$tok"
TELEGRAM_CHAT_ID="$chat"
NODE_LABEL="$label"
RPC="http://127.0.0.1:26657"
APP_SERVICE="celestia-appd"
FIBRE_SERVICE="$fib"
BRIDGE_SERVICE="$br"
FIBRE_PORT=7980
DISK_PATHS="$disks"
DISK_ALERT_PERCENT=85
MIN_PEERS=3
MISSED_ALERT=5
STALL_MINUTES=3
REMIND_MINUTES=60
DAILY_REPORT_HOUR=9
EOF
  fi
  chown root:celestiawatch /etc/celestiawatch/config.env
  chmod 640 /etc/celestiawatch/config.env

  cat > /etc/systemd/system/celestiawatch.service <<'EOF'
[Unit]
Description=celestiawatch Celestia validator + Fibre izleme
After=network-online.target

[Service]
Type=oneshot
User=celestiawatch
Group=celestiawatch
ExecStart=/usr/local/bin/celestiawatch watch
StateDirectory=celestiawatch
TimeoutStartSec=50
Nice=10
MemoryMax=100M
CPUQuota=20%
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
EOF

  cat > /etc/systemd/system/celestiawatch.timer <<'EOF'
[Unit]
Description=celestiawatch her dakika kontrol

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now celestiawatch.timer
  echo; /usr/local/bin/celestiawatch test
  echo; echo "Kurulum tamam. Ayrıntılı kontrol için: sudo celestiawatch doctor"
  echo "Ayarlar: /etc/celestiawatch/config.env | Kayıtlar: journalctl -u celestiawatch"
}

cmd_uninstall() {
  [ "$(id -u)" = "0" ] || { echo "Kaldırmak için: sudo celestiawatch uninstall"; exit 1; }
  systemctl disable --now celestiawatch.timer 2>/dev/null
  rm -f /etc/systemd/system/celestiawatch.service /etc/systemd/system/celestiawatch.timer
  systemctl daemon-reload
  rm -rf /etc/celestiawatch /var/lib/celestiawatch /usr/local/bin/celestiawatch
  id celestiawatch >/dev/null 2>&1 && userdel celestiawatch
  echo "celestiawatch tamamen kaldırıldı. Node'unuza hiçbir şey olmadı."
}

case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  watch)     cmd_watch ;;
  doctor)    cmd_doctor ;;
  status)    cmd_status ;;
  test)      cmd_test ;;
  version)   echo "celestiawatch $VERSION" ;;
  *) echo "Kullanım: celestiawatch {install|doctor|status|test|uninstall}"; exit 1 ;;
esac
