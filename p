#!/usr/bin/env bash
# preflight.sh - READ-ONLY readiness check for installing akvorado-platform on RHEL 9 from GitHub.
#
# It installs nothing, changes nothing, deletes nothing and writes no file (not even a temporary one). It downloads at most ~50 MiB of release bytes,
# straight to /dev/null, to measure how the network path (proxy / TLS inspection) behaves for ranged downloads. It never prints a password or token.
# Credentials: the GitHub token arrives on file descriptor 3 (typed at a hidden prompt by the one-liner in docs/PREFLIGHT.md) and is handed to curl
# through a process-substitution config - never in a command line, an environment variable or a file.
set +x; set -u; export LC_ALL=C; umask 077
REPO="jaber717/Akvorado"; VER=${AKV_VERSION:-1.1.0-rc1}; API="https://api.github.com"; ASSET_HOST="release-assets.githubusercontent.com"
if [ "${AKV_TEST_MODE:-0}" = 1 ] && [ -n "${AKV_API_BASE:-}" ]; then case "$AKV_API_BASE" in https://127.0.0.1:*|https://localhost:*) API=$AKV_API_BASE ;; *) echo "AKV_API_BASE may only be loopback"; exit 2 ;; esac; fi
P=0; W=0; F=0; NEXTS=()
pass() { printf '  PASS  %s\n' "$*"; P=$((P+1)); }
warn() { printf '  WARN  %s\n' "$*"; W=$((W+1)); }
fail() { printf '  FAIL  %s\n' "$1"; F=$((F+1)); NEXTS+=("${2:-see the FAIL line above}"); return 0; }
info() { printf '  INFO  %s\n' "$*"; }
sec()  { printf '\n[%s]\n' "$*"; }
mask() { sed -E 's#(://)[^/@ ]+@#\1***@#g'; }
human() { awk -v b="$1" 'BEGIN{ if (b>=1073741824) printf "%.1f GiB", b/1073741824; else printf "%.0f MiB", b/1048576 }'; }

K=""; { IFS= read -r K <&3; } 2>/dev/null || true; K=${K//[$'\r\n\t ']/}
# no token on FD 3 (e.g. started as "curl ... | bash"): offer an OPTIONAL hidden prompt on the terminal; Enter skips the private-repository checks
if [ -z "$K" ] && [ "${AKV_NO_PROMPT:-0}" != 1 ] && { : </dev/tty; } 2>/dev/null; then
  printf 'Optional GitHub token for the private-repository checks (hidden; just press Enter to skip): ' >/dev/tty
  IFS= read -rs K </dev/tty 2>/dev/null || true; printf '\n' >/dev/tty; K=${K//[$'\r\n\t ']/}
fi
S=""; if [ "$(id -u)" -ne 0 ]; then if sudo -n true 2>/dev/null; then S="sudo -n"; else S="NONE"; fi; fi
rootcmd() { if [ "$S" = NONE ]; then return 99; fi; $S "$@"; }

echo "Akvorado production preflight (READ-ONLY)   $(date -u '+%F %T UTC')   host: $(hostname -f 2>/dev/null || hostname)   target release: v$VER"

# ----------------------------------------------------------------------------------------------------------------------------------- SYSTEM
sec "SYSTEM"
. /etc/os-release 2>/dev/null
case "${ID:-}:${VERSION_ID:-}" in
  rhel:9.7) pass "Red Hat Enterprise Linux 9.7" ;;
  rhel:9.*) pass "Red Hat Enterprise Linux ${VERSION_ID} (supported; 9.7 is the target)" ;;
  *) if [[ "${VERSION_ID:-}" == 9.* ]]; then warn "${PRETTY_NAME:-unknown} is an EL9 clone: the installer accepts it only in test mode"; else fail "${PRETTY_NAME:-unknown OS} is not supported (RHEL 9.x required)" "use a RHEL 9.x host"; fi ;;
esac
[ "$(uname -m)" = x86_64 ] && pass "architecture x86_64" || fail "architecture $(uname -m) is not supported" "x86_64 required"
cpu=$(nproc); ram=$(awk '/MemTotal/{printf "%d",$2/1048576+0.5}' /proc/meminfo)
if [ "$cpu" -ge 4 ]; then pass "CPU: $cpu vCPU"; elif [ "$cpu" -ge 2 ]; then warn "CPU: $cpu vCPU (4 recommended)"; else fail "CPU: $cpu vCPU (minimum 2)" "add vCPUs"; fi
if [ "$ram" -ge 8 ]; then pass "RAM: ${ram} GiB"; elif [ "$ram" -ge 6 ]; then warn "RAM: ${ram} GiB (8 recommended)"; else fail "RAM: ${ram} GiB (minimum 6)" "add memory"; fi
[ "$(getenforce 2>/dev/null)" = Enforcing ] && pass "SELinux Enforcing" || fail "SELinux is $(getenforce 2>/dev/null) (the platform requires Enforcing)" "set SELinux to Enforcing"
systemctl is-active --quiet firewalld && pass "firewalld active" || fail "firewalld is not active (the platform manages its ports through it)" "start firewalld"
[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && pass "clock is NTP-synchronized" || warn "clock is not NTP-synchronized (flow timestamps and certificates depend on it)"
miss=""; for t in curl tar sha256sum python3 openssl awk sed; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
[ -z "$miss" ] && pass "required tools present (curl tar sha256sum python3 openssl)" || fail "missing tools:$miss" "install them from your RHEL repositories"
if [ "$(id -u)" -eq 0 ]; then pass "running as root"; elif [ "$S" = "sudo -n" ]; then pass "passwordless sudo available (needed at install time)"; else warn "no passwordless sudo: root-only checks are skipped; the installer itself must run as root"; fi

# ---------------------------------------------------------------------------------------------------------------------------------- STORAGE
sec "STORAGE (the installer never formats or deletes anything)"
if mountpoint -q /data/netflow 2>/dev/null; then
  fs=$(findmnt -no FSTYPE /data/netflow); fr=$(df -BG --output=avail /data/netflow | tail -1 | tr -dc 0-9)
  [ "$(findmnt -no SOURCE /)" != "$(findmnt -no SOURCE /data/netflow)" ] && pass "/data/netflow is a dedicated mount ($fs, ${fr} GiB free)" || fail "/data/netflow is on the root filesystem" "mount a dedicated volume there"
  [ "$fs" = xfs ] || warn "/data/netflow is $fs (XFS recommended)"
  [ "$fr" -ge 100 ] && pass "data volume free space ${fr} GiB (>= 100 GiB for 14 days of raw flows)" || { [ "$fr" -ge 30 ] && warn "data volume free space ${fr} GiB (100 GiB+ recommended)" || fail "data volume free space ${fr} GiB" "enlarge the data volume"; }
else
  cand=$(df -BG -x tmpfs -x devtmpfs -x squashfs --output=target,avail,fstype 2>/dev/null | awk 'NR>1 && $1!="/" && $1!="/boot" && $1!~"^/boot/" && $1!="/home" && $2+0>=100 {print $1" ("$2" free, "$3")"}' | head -3 | tr '\n' ';')
  if [ -n "$cand" ]; then warn "/data/netflow is not mounted; mounted volumes that could serve as the data directory: $cand set NETFLOW_DATA_DIR to one of them"
  else fail "no dedicated data filesystem found (/data/netflow is not a mount point and no other mounted volume has 100 GiB free)" "attach a data disk, create the filesystem and mount it (the installer will not do it)"; fi
  un=$(lsblk -rno NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | awk '$2=="disk" || $2=="part" {n[$1]=1} {print}' | awk '$2=="disk" && $4=="" && $5=="" {print $1" "$3}' | head -3 | tr '\n' ';')
  [ -n "$un" ] && info "unused raw disk(s) seen (not touched, not formatted): $un"
fi
rf=$(df -BG --output=avail / | tail -1 | tr -dc 0-9); [ "$rf" -ge 15 ] && pass "root filesystem free ${rf} GiB" || { [ "$rf" -ge 8 ] && warn "root filesystem free ${rf} GiB (15 GiB+ recommended)" || fail "root filesystem free ${rf} GiB" "free space on /"; }

# --------------------------------------------------------------------------------------------------------------------------------- CONFLICTS
sec "EXISTING SOFTWARE"
if [ -e /etc/akvorado-platform/release.json ]; then info "akvorado-platform is already installed here (a re-run is idempotent and keeps data)"
elif [ -e /opt/netflow/akvorado ] || [ -e /opt/akvorado-platform ]; then fail "an Akvorado deployment that akvorado-platform did not install exists (/opt/netflow or /opt/akvorado-platform): the installer refuses to touch it" "tell us what it is before installing"
else pass "no previous Akvorado/NetFlow deployment found"; fi
rpm -q docker-ce >/dev/null 2>&1 && info "Docker CE already installed ($(rpm -q docker-ce | head -1)); the release supplies its own pinned version" || pass "Docker is not installed (the release supplies it)"
busy=$(rootcmd ss -lntuH 2>/dev/null | awk '{print $5}' | grep -E ':(443|2055|4739|6343|8443|9092|9000|8123)$' | tr '\n' ' ')
if [ "$S" = NONE ] && [ "$(id -u)" -ne 0 ]; then warn "port check skipped (needs root)"; elif [ -z "$busy" ]; then pass "ports 443, 2055/udp, 4739/udp, 6343/udp, 8443 are free"; else fail "ports already in use: $busy" "stop what uses them"; fi

# --------------------------------------------------------------------------------------------------------------------------------- PROXY + CA
sec "PROXY AND CERTIFICATES (detected automatically)"
PROXY=""; PSRC=""
for v in https_proxy HTTPS_PROXY all_proxy ALL_PROXY; do [ -z "$PROXY" ] && [ -n "${!v:-}" ] && { PROXY=${!v}; PSRC="environment ($v)"; }; done
if [ -z "$PROXY" ]; then
  for f in /etc/environment /etc/profile /etc/profile.d/*.sh /etc/bashrc; do
    [ -z "$PROXY" ] && [ -r "$f" ] && x=$(grep -hiE '^[[:space:]]*(export[[:space:]]+)?(https_proxy|all_proxy)=' "$f" 2>/dev/null | head -1 | sed -E "s/^[^=]*=//; s/[\"']//g") && [ -n "$x" ] && { PROXY=$x; PSRC="$f"; }
  done
fi
if [ -z "$PROXY" ] && [ -r /etc/dnf/dnf.conf ]; then x=$(sed -n 's/^proxy[[:space:]]*=[[:space:]]*//p' /etc/dnf/dnf.conf | head -1 | tr -d ' '); [ -n "$x" ] && { PROXY=$x; PSRC="/etc/dnf/dnf.conf"; }; fi
PUSER=""; PURL=$PROXY
if [[ "$PROXY" =~ ^([a-z0-9]+://)([^/@]+)@(.*)$ ]]; then PUSER=${BASH_REMATCH[2]}; PURL="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"; fi
[ -n "$PROXY" ] && pass "proxy found in $PSRC: $(echo "$PURL" | mask)${PUSER:+ (credentials present, hidden)}" || info "no proxy configured: connecting directly"
if [ -n "${https_proxy:-}${HTTPS_PROXY:-}" ] && [ "$(id -u)" -ne 0 ] && [ "$S" != NONE ]; then
  n=$($S env 2>/dev/null | grep -ciE '^https?_proxy=' || true); [ "${n:-0}" -ge 1 ] && info "sudo keeps the proxy variables on this host" || warn "'sudo' DROPS the proxy variables on this host: the installer therefore reads the proxy from system files or its own saved settings, not from your shell"
fi
tl=$(trust list 2>/dev/null | grep -iE 'label:.*(forti|proxy|inspect|firewall|zscaler|bluecoat|sonicwall|palo)' | head -2 | sed 's/^ *//' | tr '\n' ';'); [ -n "$tl" ] && info "inspection-style CA in the system trust store: $tl"
ARGS=(--proto '=https' --tlsv1.2 -sS --connect-timeout 20)
if [ -n "$PURL" ]; then ARGS+=(--proxy "$PURL"); else ARGS+=(--noproxy '*'); fi
[ "${AKV_TEST_MODE:-0}" = 1 ] && [ -n "${AKV_CA_BUNDLE:-}" ] && ARGS+=(--cacert "$AKV_CA_BUNDLE")
cfg() { [ -n "$K" ] && printf 'header = "Authorization: Bearer %s"\n' "$K"; [ -n "$PUSER" ] && printf 'proxy-user = "%s"\n' "$PUSER"; printf '#\n'; }
# AKV_CA=<pem of your corporate TLS-inspection CA>: it is ADDED to the system trust store for these requests (merged on the fly, no file written); verification stays on
sysca() { cat /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null || cat /etc/ssl/certs/ca-certificates.crt; }
cafile() { sysca; cat "$AKV_CA"; }
if [ -n "${AKV_CA:-}" ]; then
  [ -r "$AKV_CA" ] && grep -q "BEGIN CERTIFICATE" "$AKV_CA" && ! grep -q "PRIVATE KEY" "$AKV_CA" && info "extra CA from AKV_CA is added to the system trust store (verification stays on)" || { fail "AKV_CA=$AKV_CA is not a readable PEM certificate (or contains a private key)" "pass the CA CERTIFICATE (not a key) in PEM format"; AKV_CA=""; }
fi
cx() { if [ -n "${AKV_CA:-}" ]; then curl "${ARGS[@]}" --cacert <(cafile) -K <(cfg) "$@"; else curl "${ARGS[@]}" -K <(cfg) "$@"; fi; }
cxn() { if [ -n "${AKV_CA:-}" ]; then curl "${ARGS[@]}" --cacert <(cafile) "$@"; else curl "${ARGS[@]}" "$@"; fi; }   # without the token (storage host)
issuer() { local h=$1 px=""; [ -n "$PURL" ] && px="-proxy $(echo "$PURL" | sed -E 's#^[a-z0-9]+://##; s#/.*##')"; timeout 20 openssl s_client $px -connect "$h:443" -servername "$h" </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//'; }
proxyfail() { # $1 curl error text -> message
  local t=$1 c=""
  c=$(echo "$t" | sed -nE 's/.*CONNECT tunnel failed, response ([0-9]+).*/\1/p; s/.*HTTP code ([0-9]+) from proxy after CONNECT.*/\1/p' | head -1)
  case "$c" in
    407) echo "the PROXY demands authentication (HTTP 407): provide the proxy credentials (user:password) when the installer asks" ;;
    403) echo "the proxy REFUSED the tunnel (HTTP 403): policy blocks this GitHub host - ask the firewall team to allow api.github.com and release-assets.githubusercontent.com on 443" ;;
    502|503|504) echo "the proxy answered HTTP $c while opening the tunnel (gateway/timeout on the proxy side)" ;;
    "") case "$t" in
          *"(60)"*|*"(35)"*|*"(51)"*|*"(58)"*|*"(77)"*) echo "TLS verification FAILED: the certificate presented is not trusted by this host (corporate TLS-inspection CA missing from the trust store); verification is never disabled" ;;
          *"(5)"*) echo "the proxy host name cannot be resolved" ;; *"(6)"*) echo "DNS cannot resolve the GitHub host (no proxy configured?)" ;;
          *"(7)"*) echo "cannot connect (no route / firewall / wrong proxy address or port)" ;; *"(28)"*) echo "connection timed out" ;; *) echo "$(echo "$t" | head -1 | cut -c1-140)" ;; esac ;;
    *) echo "proxy answered HTTP $c while opening the tunnel" ;;
  esac
}

# ------------------------------------------------------------------------------------------------------------------------------------ GITHUB
sec "GITHUB: api.github.com and $ASSET_HOST (HTTPS 443 only)"
for h in api.github.com "$ASSET_HOST"; do
  if [ "${AKV_TEST_MODE:-0}" = 1 ]; then :; elif [ -n "$PURL" ]; then info "$h is resolved by the proxy"; else getent hosts "$h" >/dev/null 2>&1 && pass "DNS: $h resolves" || fail "DNS: $h does not resolve" "fix DNS or configure the proxy"; fi
done
out=$(cx -o /dev/null -w '\nRES %{http_code} %{ssl_verify_result}\n' "$API/zen" 2>&1); res=$(echo "$out" | sed -n 's/^RES //p')
if [ "${res%% *}" = 200 ]; then pass "api.github.com reachable, TLS verified"; iss=$(issuer api.github.com); case "$iss" in *Sectigo*|*DigiCert*|*"Let's Encrypt"*|*GlobalSign*|*Amazon*|*Microsoft*|*"Google Trust"*) info "certificate issuer: $iss" ;; "") ;; *) warn "TLS inspection detected: api.github.com certificate issued by: $iss (trusted by this host, so verification passes)" ;; esac
else m=$(proxyfail "$out"); fail "api.github.com NOT reachable: $m" "$m"; iss=$(issuer api.github.com); [ -n "$iss" ] && info "certificate presented for api.github.com: $iss"; fi
if [ "${AKV_TEST_MODE:-0}" = 1 ]; then out2=""; res2="200 0"; else out2=$(cxn -o /dev/null -w '\nRES %{http_code} %{ssl_verify_result}\n' "https://$ASSET_HOST/" 2>&1); res2=$(echo "$out2" | sed -n 's/^RES //p'); fi
if [ -n "$res2" ] && [ "${res2##* }" = 0 ] && [ "${res2%% *}" != 000 ]; then pass "$ASSET_HOST reachable, TLS verified (HTTP ${res2%% *} is expected for the bare host)"; iss=$(issuer "$ASSET_HOST"); case "$iss" in *Sectigo*|*DigiCert*|*"Let's Encrypt"*|*GlobalSign*|*Amazon*|*Microsoft*|*"Google Trust"*|"") ;; *) warn "TLS inspection detected for $ASSET_HOST: issued by $iss" ;; esac
else m=$(proxyfail "$out2"); fail "$ASSET_HOST NOT reachable: $m (the actual asset bytes come from this host)" "$m"; fi

REL=""; ASSETID=""; ASSETSIZE=0; ASSETNAME=""; MAN=""
if [ -z "$K" ]; then warn "no GitHub token supplied: the private-repository checks (authentication, release, ranged download) are skipped"
else
  st=$(cx -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.github+json' "$API/repos/$REPO" 2>&1 | tail -1)
  case "$st" in
    200) pass "GitHub authentication: the token can read $REPO" ;;
    401) fail "GitHub token rejected (HTTP 401: invalid, expired or revoked)" "create a new fine-grained token: repository $REPO only, permission Contents: Read-only" ;;
    403) fail "GitHub refused the token (HTTP 403: missing Contents:read, SSO authorisation needed, or a proxy block)" "check the token scope, SSO authorisation and the proxy" ;;
    404) fail "GitHub answers 404: the token cannot see $REPO (wrong repository scope)" "create the fine-grained token for repository $REPO with Contents: Read-only" ;;
    429) fail "GitHub rate limit (HTTP 429)" "wait a few minutes and run the command again" ;;
    *) fail "GitHub check failed ($(echo "$st" | cut -c1-120))" "$(proxyfail "$st")" ;;
  esac
  if [ "$st" = 200 ]; then
    REL=$(cx -H 'Accept: application/vnd.github+json' "$API/repos/$REPO/releases/tags/v$VER" 2>/dev/null)
    meta=$(printf '%s' "$REL" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("ERR"); sys.exit()
a=d.get("assets",[])
big=max(a,key=lambda x:x["size"]) if a else None
bad=[x["name"] for x in a if x.get("state")!="uploaded"]
print("OK|%s|%d|%s|%s|%d|%s|%s" % (d.get("tag_name"),len(a),str(d.get("prerelease")).lower(),big["id"] if big else "",big["size"] if big else 0,big["name"] if big else "",",".join(bad)))
' 2>/dev/null)
    case "$meta" in
      OK\|*) IFS='|' read -r _ tag n pre ASSETID ASSETSIZE ASSETNAME bad <<<"$meta"
         [ -z "$bad" ] && pass "release $tag found: $n assets, all uploaded$([ "$pre" = true ] && echo ' (pre-release)')" || fail "release $tag has assets that are not finished: $bad" "wait for the release to complete"
         tot=$(printf '%s' "$REL" | python3 -c 'import json,sys;print(sum(x["size"] for x in json.load(sys.stdin)["assets"]))' 2>/dev/null); info "total download: $(human "${tot:-0}") in $n files (the largest is $(human "$ASSETSIZE"))"; DL=${tot:-0} ;;
      *) fail "release v$VER not found or unreadable" "check the version and the token's repository access" ;;
    esac
  fi
fi

# ----------------------------------------------------------------------------------------------- RANGE / LARGE-DOWNLOAD BEHAVIOUR THROUGH THE PROXY
if [ -n "$ASSETID" ]; then
  sec "LARGE DOWNLOADS: signed asset URL and ranged requests (bytes go to /dev/null)"
  hd=$(cx -H 'Accept: application/octet-stream' -o /dev/null -w 'CODE %{http_code}\nURL %{redirect_url}\n' "$API/repos/$REPO/releases/assets/$ASSETID" 2>&1); code=$(echo "$hd" | sed -n 's/^CODE //p'); url=$(echo "$hd" | sed -n 's/^URL //p')
  if [ "$code" = 302 ] && [ -n "$url" ]; then
    h=$(echo "$url" | sed -E 's#^https://([^/]+)/.*#\1#'); [ "$h" = "$ASSET_HOST" ] && pass "asset download redirects to $ASSET_HOST (expected)" || warn "asset download redirects to $h (expected $ASSET_HOST): allow that host too"
    best=""; slow=0
    for mb in 1 16 32; do
      from=$(( (mb==1 ? 0 : 3) * 1048576 )); [ "$ASSETSIZE" -le $(( (3+mb) * 1048576 )) ] && from=0; to=$(( from + mb*1048576 - 1 )); [ "$to" -ge "$ASSETSIZE" ] && to=$((ASSETSIZE-1))
      want=$((to-from+1))
      r=$(cxn -m 180 -H 'Accept-Encoding: identity' -r "$from-$to" -D - -o /dev/null -w '\nRES %{http_code} %{size_download} %{time_total}\n' "$url" 2>&1)
      rs=$(echo "$r" | sed -n 's/^RES //p'); c=${rs%% *}; rest=${rs#* }; got=${rest%% *}; tm=${rest##* }
      cr=$(echo "$r" | tr -d '\r' | sed -n 's/^[Cc]ontent-[Rr]ange: *//p' | head -1); ce=$(echo "$r" | tr -d '\r' | sed -n 's/^[Cc]ontent-[Ee]ncoding: *//p' | head -1)
      spd=$(awk -v b="${got:-0}" -v t="${tm:-1}" 'BEGIN{ if (t<=0) t=1; printf "%.1f", b/1048576/t }')
      if [ "$c" = 206 ] && [ "$got" = "$want" ] && [ "${cr%% *}" = "bytes" ] && { [ -z "$ce" ] || [ "$ce" = identity ]; }; then
        if awk -v s="$spd" 'BEGIN{exit !(s<0.5)}'; then warn "${mb} MiB ranged request OK but slow (${spd} MiB/s)"; slow=1; else pass "${mb} MiB ranged request OK (HTTP 206, ${spd} MiB/s, Content-Range correct, no re-encoding)"; best=$mb; fi
      elif [ "$c" = 200 ]; then fail "the network path IGNORES HTTP Range (answered 200 for a ranged request)" "the installer needs Range support; ask the proxy team to disable download buffering/AV scanning for these hosts, or use the explicit stream fallback"; break
      elif [ -n "$ce" ] && [ "$ce" != identity ]; then fail "the proxy re-encoded the response (Content-Encoding: $ce)" "exempt api.github.com and $ASSET_HOST from content modification"; break
      else m=$(proxyfail "$r"); [ "$c" = 504 ] || [ "$c" = 502 ] || [ "$c" = 503 ] && m="HTTP $c from the proxy/GitHub for a ${mb} MiB range"; if [ "$mb" = 1 ]; then fail "ranged download FAILED ($m)" "$m"; break; else warn "${mb} MiB ranged request failed ($m): the installer will use smaller chunks"; fi; fi
    done
    [ -n "$best" ] && info "recommended download chunk size for this network: ${best} MiB (installer default 16 MiB; it falls back to smaller chunks automatically)"
  else m=$(proxyfail "$hd"); fail "could not obtain the asset download URL (HTTP ${code:-none}) $m" "${m:-check the token and the proxy}"; fi
fi

# ------------------------------------------------------------------------------------------------------------------------------------ SPACE
if [ "${DL:-0}" -gt 0 ]; then
  sec "DISK SPACE FOR THE DOWNLOAD (staging and container images live under /var/lib)"
  p=/var/lib; fr=$(df -B1 --output=avail "$p" | tail -1 | tr -dc 0-9); need=$(( DL + DL/5 + 3*1024*1024*1024 ))
  [ "$fr" -ge "$need" ] && pass "free space under /var/lib: $(human "$fr") (needs about $(human "$need"))" || fail "free space under /var/lib: $(human "$fr"), needs about $(human "$need")" "free space or mount more storage under /var/lib"
fi

# ---------------------------------------------------------------------------------------------------------------------------------- SUMMARY
printf '\n'; if [ "$F" -gt 0 ]; then r="NOT READY"; elif [ "$W" -gt 0 ]; then r="READY WITH WARNINGS"; else r="READY"; fi
printf 'RESULT: %d PASS, %d WARN, %d FAIL  ->  %s\n' "$P" "$W" "$F" "$r"
if [ "${#NEXTS[@]}" -gt 0 ]; then echo "NEXT ACTIONS (most relevant first):"; printf '%s\n' "${NEXTS[@]}" | awk '!s[$0]++' | head -4 | nl -w2 -s'. '; fi
printf '(nothing was installed, changed or deleted; no secret was printed)\n'
[ "$F" -eq 0 ]
