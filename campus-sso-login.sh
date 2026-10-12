#!/usr/bin/env bash
#
# campus-sso-login.sh - headless campus-network login for the HSTC Dr.COM portal
# that fronts the school CAS single sign-on ("unified identity").
#
#   portal : http://rz.hstc.edu.cn/    (same host as http://192.168.2.34/)
#   CAS    : https://hscas.hstc.edu.cn/cas/
#
# How the flow was derived (from the portal's own JavaScript, not guesswork):
#
#   1) While unauthenticated, http://connect.rom.miui.com/generate_204 is
#      intercepted and answered with 200 + a redirect page:
#        <script>top.self.location.href='https://rz.hstc.edu.cn/a79.htm
#          ?wlanuserip=..&usermac=..&wlanacip=..&wlanacname=..&...'</script>
#      Those four values identify this client. The backend does NOT validate
#      them (it echoes whatever you send), so they must come from the real
#      redirect, otherwise the session gets bound to the wrong IP/MAC.
#
#   2) The portal page template registers an authorisation link:
#        GET {portal_api}cas/create?login_method=1
#              &wlan_user_ip=..&wlan_user_mac=..&wlan_ac_ip=..&wlan_ac_name=..
#        -> {"result":1,"authorize_uri":"https://.../cas/login?service=<urlenc>"}
#
#   3) CAS serves its login page with a per-session `execution` token. The RSA
#      public key is at /cas/jwt/publicKey; the password is encrypted with
#      PKCS#1 v1.5 and prefixed with "__RSA__" (that is what JSEncrypt does).
#      Form fields: username, password, execution, _eventId=submit,
#      geolocation, mfaState, currentMenu=1, failN=-1
#
#   4) A successful POST redirects to  service?ticket=ST-...  and the portal
#      then completes the network authentication.
#
# Logging out mirrors logout.default_logout() -> portal_logout() ->
# custom.identity_logout():
#      GET <portal>/drcom/logout?callback=..&jsVersion=4.1
#      GET <portal>:801/eportal/portal/cas/logout?wlan_user_ip=..
#
# If CAS already trusts this client (IP-level SSO, or the authorisation link it
# just registered) it returns a ticket straight away, with no login form at all.
# That path is handled as well, and needs no credentials.
#
# Usage:
#   ./campus-sso-login.sh            login if not already online
#   ./campus-sso-login.sh --check    only report the online state
#   ./campus-sso-login.sh --logout   log out (portal, then CAS single sign-on)
#   ./campus-sso-login.sh --force    ignore the online state
#   ./campus-sso-login.sh --dry-run  walk the chain, never submit a password
#
# Configuration: campus.conf next to this script, or environment variables
#   CAMPUS_USER / CAMPUS_PASS. Credentials are only requested when the CAS login
#   form is actually needed (prompted on a TTY, password is not echoed).
#   Nothing is written to disk: the password only ever lives in this process,
#   and the cookie jar is deleted on exit.
#
set -u
umask 077                      # cookie jar and dumps stay private to this user

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${CAMPUS_CONF:-$SELF_DIR/campus.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

USERNAME="${CAMPUS_USER:-}"
PASSWORD="${CAMPUS_PASS:-}"
FORCE_REDIRECT="${CAMPUS_REDIRECT:-}"
PROBE="${CAMPUS_PROBE:-http://connect.rom.miui.com/generate_204}"
PORTAL="${CAMPUS_PORTAL:-https://rz.hstc.edu.cn}"
EP_HTTP_PORT="${CAMPUS_EP_HTTP_PORT:-801}"
CAS_BASE="${CAMPUS_CAS:-https://hscas.hstc.edu.cn/cas}"
UA="${CAMPUS_UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36}"
WORK="${CAMPUS_WORK:-/tmp/campus-sso}"
LOG="${CAMPUS_LOG:-/tmp/campus-sso-login.log}"

CHECK=0; FORCE=0; DRY=0; LOGOUT=0
for arg in "$@"; do case "$arg" in
  --check)   CHECK=1 ;;
  --logout)  LOGOUT=1 ;;
  --force)   FORCE=1 ;;
  --dry-run) DRY=1; FORCE=1 ;;
  -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
  *) echo "unknown option: $arg" >&2; exit 2 ;;
esac; done

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
die(){ log "ERROR: $*"; exit 1; }

command -v curl    >/dev/null 2>&1 || die "curl not found"
command -v openssl >/dev/null 2>&1 || die "openssl not found"
command -v base64  >/dev/null 2>&1 || die "base64 not found"

mkdir -p "$WORK"; chmod 700 "$WORK" 2>/dev/null
JAR="$WORK/cookies.txt"; rm -f "$JAR"
# The jar can hold a CAS session cookie, which is a reusable credential.
trap 'rm -f "$JAR" 2>/dev/null' EXIT

online(){ [ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 -A "$UA" "$PROBE" 2>/dev/null)" = "204" ]; }

local_ip(){
  if command -v ip >/dev/null 2>&1; then
    ip route get 1.1.1.1 2>/dev/null | LC_ALL=C grep -oE 'src [0-9.]+' | awk '{print $2}'
  else
    ipconfig getifaddr en0 2>/dev/null \
      || ifconfig 2>/dev/null | awk '/inet /{print $2}' | LC_ALL=C grep -v '^127\.' | head -1
  fi
}

# ---------------------------------------------------------------- logout
logout_now(){
  local host="${PORTAL#*//}"; host="${host%%/*}"
  local ip; ip="$(local_ip)"
  log "logging out of the portal: $PORTAL/drcom/logout"

  local r1
  r1="$(curl -sS -m 12 -A "$UA" -G "$PORTAL/drcom/logout" \
        --data-urlencode "callback=dr$RANDOM$RANDOM" \
        --data-urlencode "jsVersion=4.1" 2>/dev/null)"
  log "drcom/logout -> ${r1:0:160}"

  local r2
  r2="$(curl -sS -m 12 -A "$UA" -G "http://$host:$EP_HTTP_PORT/eportal/portal/cas/logout" \
        --data-urlencode "callback=dr$RANDOM$RANDOM" \
        --data-urlencode "wlan_user_ip=${ip:-}" \
        --data-urlencode "jsVersion=4.2.1" 2>/dev/null)"
  log "cas/logout   -> ${r2:0:200}"

  sleep 2
  if online; then
    log "still online after logout - either the portal needs a moment, or the session belongs to a router/NAT in front of this machine"
    return 2
  fi
  log "logged out"
  return 0
}

if [ "$LOGOUT" = 1 ]; then logout_now; exit $?; fi

if [ "$FORCE" = 0 ] && online; then log "already online, nothing to do"; exit 0; fi
if [ "$CHECK" = 1 ]; then log "not online"; exit 1; fi

# Credentials are deliberately NOT collected here: cas/create does not need
# them. They are only requested further down, if CAS really serves a login form.

# ---------------------------------------------------------------- 1. client params
if [ -n "$FORCE_REDIRECT" ]; then
  REDIR="$FORCE_REDIRECT"
else
  BODY="$(curl -s -m 8 -A "$UA" "$PROBE" 2>/dev/null)"
  REDIR="$(printf '%s' "$BODY" | LC_ALL=C grep -oE "https?://[^'\"]+" | head -1)"
fi
[ -n "$REDIR" ] || die "no portal redirect captured (maybe already online - try --force)"
log "portal redirect: $REDIR"

getq(){ printf '%s' "$1" | sed -n "s/.*[?&]$2=\([^&]*\).*/\1/p"; }
SCHEME="$(printf '%s' "$REDIR" | sed -E 's#^(https?)://.*#\1#')"
PHOST="$(printf '%s' "$REDIR" | sed -E 's#^https?://([^/]+).*#\1#' | sed -E 's#:[0-9]+$##')"
WIP="$(getq "$REDIR" wlanuserip)"
UMAC="$(getq "$REDIR" usermac)"
ACIP="$(getq "$REDIR" wlanacip)"
ACNAME="$(getq "$REDIR" wlanacname)"
UMAC="$(printf '%s' "$UMAC" | tr -d ':-' | tr 'A-F' 'a-f')"
[ -n "$WIP" ] && [ -n "$UMAC" ] || die "redirect is missing wlanuserip/usermac: $REDIR"
log "ip=$WIP mac=$UMAC ac=$ACIP/$ACNAME portal=$SCHEME://$PHOST"

# The eportal API is served in plain HTTP on 801 for both the hostname and the
# bare IP, which also sidesteps any certificate trouble on port 802.
EP="http://$PHOST:$EP_HTTP_PORT/eportal/portal"

# ---------------------------------------------------------------- 2. cas/create
CREATE="$(curl -sS -m 12 -A "$UA" -G "$EP/cas/create" \
  --data-urlencode "callback=cb" \
  --data-urlencode "login_method=1" \
  --data-urlencode "wlan_user_ip=$WIP" \
  --data-urlencode "wlan_user_mac=$UMAC" \
  --data-urlencode "wlan_ac_ip=$ACIP" \
  --data-urlencode "wlan_ac_name=$ACNAME" \
  --data-urlencode "mac_type=0" \
  --data-urlencode "jsVersion=4.1" 2>/dev/null)"
log "cas/create -> ${CREATE:0:160}"

AUTHZ="$(printf '%s' "$CREATE" | sed -n 's/.*"authorize_uri":"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g')"
[ -n "$AUTHZ" ] || die "cas/create returned no authorize_uri: $CREATE"
log "authorize_uri: $AUTHZ"

# ---------------------------------------------------------------- 3. CAS entry
# CAS often answers 302 first (to drop a session cookie) before serving the
# login page, so follow a few hops manually and keep the cookie jar.
CAS_URL="$AUTHZ"; CAS_PAGE=""; TICKET_SEEN=0
for _hop in 1 2 3 4 5 6; do
  curl -sS -m 15 -A "$UA" -c "$JAR" -b "$JAR" -D "$WORK/cas.hdr" -o "$WORK/cas.body" "$CAS_URL" 2>"$WORK/cas.err"
  CAS_PAGE="$(cat "$WORK/cas.body" 2>/dev/null)"
  ST="$(LC_ALL=C head -1 "$WORK/cas.hdr" 2>/dev/null | sed -n 's#^HTTP/[0-9.]* \([0-9]*\).*#\1#p')"
  LOC="$(LC_ALL=C grep -i '^location:' "$WORK/cas.hdr" 2>/dev/null | head -1 | sed 's/^[Ll]ocation:[[:space:]]*//' | tr -d '\r')"
  log "cas page: HTTP ${ST:-?}, ${#CAS_PAGE} bytes"
  case "$ST" in 30*) ;; *) break ;; esac
  [ -n "$LOC" ] || break
  case "$LOC" in *ticket=ST-*) TICKET_SEEN=1 ;; esac
  case "$LOC" in
    http*) ;;
    /*) LOC="$(printf '%s' "$CAS_URL" | sed -E 's#^(https?://[^/]+).*#\1#')$LOC" ;;
    *)  LOC="$(printf '%s' "$CAS_URL" | sed -E 's#^(https?://[^/]+).*#\1#')/$LOC" ;;
  esac
  log "  -> following Location: $LOC"
  CAS_URL="$LOC"
done
printf '%s' "$CAS_PAGE" > "$WORK/cas-login.html"

if [ -z "$CAS_PAGE" ]; then
  log "CAS page is empty, curl said: $(tr -d '\n' < "$WORK/cas.err" 2>/dev/null)"
  log "authorize_uri = [$AUTHZ]"
  die "CAS server was not reached (details in $WORK/cas.err)"
fi

if [ "$TICKET_SEEN" = 1 ]; then
  log "CAS issued a ticket without asking for credentials"
  sleep 2
  if online; then log "login OK, network is up"; exit 0; fi
  log "ticket was seen but the probe is still not 204 - falling back to the login form"
fi

EXEC="$(printf '%s' "$CAS_PAGE" | tr '>' '\n' \
        | LC_ALL=C grep -o 'name="execution"[[:space:]]\+value="[^"]*"' \
        | sed -n 's/.*value="\([^"]*\)".*/\1/p' | LC_ALL=C grep -v '\$' | head -1)"
[ -n "$EXEC" ] || die "no execution token (page saved at $WORK/cas-login.html)"
log "execution: ${EXEC:0:32}..."

# ---------------------------------------------------------------- 4. RSA encrypt
# Reaching this point means CAS really wants the login form filled in, so this
# is where credentials become necessary.
if [ -z "$USERNAME" ] && [ -t 0 ]; then printf 'Student/Staff ID: ' >&2; read -r USERNAME; fi
if [ -z "$PASSWORD" ] && [ -t 0 ]; then printf 'Unified-auth password (not echoed): ' >&2; read -rs PASSWORD; echo >&2; fi
[ -n "$USERNAME" ] || die "account required: set CAMPUS_USER in $CONF or type it in"
[ -n "$PASSWORD" ] || die "password required: set CAMPUS_PASS in $CONF or type it in"

PUB="$WORK/cas_pub.pem"
curl -sS -m 15 -A "$UA" "$CAS_BASE/jwt/publicKey" -o "$PUB" 2>/dev/null
LC_ALL=C grep -q 'BEGIN PUBLIC KEY' "$PUB" || die "could not fetch the CAS public key"
ENC="$(printf '%s' "$PASSWORD" \
      | openssl pkeyutl -encrypt -pubin -inkey "$PUB" -pkeyopt rsa_padding_mode:pkcs1 2>/dev/null \
      | base64 | tr -d '\n')"
[ -n "$ENC" ] || die "RSA encryption failed"
log "password RSA-encrypted ($(printf '%s' "$ENC" | wc -c | tr -d ' ') base64 chars)"

if [ "$DRY" = 1 ]; then
  log "dry-run finished: the whole chain parsed fine, no password was submitted"
  log "would submit: username=$USERNAME password=__RSA__<hidden> execution=${EXEC:0:20}... _eventId=submit currentMenu=1 failN=-1"
  exit 0
fi

# ---------------------------------------------------------------- 5. POST to CAS
# The encrypted password is fed through stdin (--data-urlencode password@-) so it
# never shows up in the process list.
HDR="$WORK/post.hdr"; OUT="$WORK/post.html"
printf '%s' "__RSA__$ENC" | curl -sS -m 25 -A "$UA" -b "$JAR" -c "$JAR" -L --max-redirs 10 \
  -H "Referer: $AUTHZ" -H "Origin: ${CAS_BASE%/cas}" \
  -D "$HDR" -o "$OUT" \
  --data-urlencode "username=$USERNAME" \
  --data-urlencode "password@-" \
  --data-urlencode "execution=$EXEC" \
  --data-urlencode "_eventId=submit" \
  --data-urlencode "geolocation=" \
  --data-urlencode "mfaState=" \
  --data-urlencode "currentMenu=1" \
  --data-urlencode "failN=-1" \
  "$AUTHZ" 2>/dev/null

if LC_ALL=C grep -qi 'ticket=ST-' "$HDR"; then
  log "CAS issued a ticket"
else
  MSG="$(LC_ALL=C grep -oE 'id="loginError1"[^>]*>[^<]*|msg["'\'': ]+[^,}"<]{2,60}' "$OUT" 2>/dev/null | head -2 | tr '\n' ' ')"
  log "no ticket seen, CAS probably rejected this login. hint: ${MSG:-none}"
fi

# ---------------------------------------------------------------- 6. verify
sleep 2
if online; then log "login OK, network is up"; exit 0; fi
log "still offline. dumps: $HDR  $OUT"
exit 2
