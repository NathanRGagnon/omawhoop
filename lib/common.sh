# Shared paths and helpers for omawhoop-auth / omawhoop-status /
# omawhoop-history. Sourced, not executed.

# Everything this plugin writes (config, tokens, cache) is private to the user,
# including the brief window before an explicit chmod.
umask 077

readonly OMAWHOOP_CONFIG_DIR="$HOME/.config/omawhoop"
readonly OMAWHOOP_CONFIG_FILE="$OMAWHOOP_CONFIG_DIR/config"
readonly OMAWHOOP_STATE_DIR="$HOME/.local/state/omawhoop"
readonly OMAWHOOP_TOKENS_FILE="$OMAWHOOP_STATE_DIR/tokens.json"
readonly OMAWHOOP_CACHE_DIR="$HOME/.cache/omawhoop"
readonly OMAWHOOP_CACHE_FILE="$OMAWHOOP_CACHE_DIR/status.json"

readonly OMAWHOOP_REDIRECT_PORT=8942
readonly OMAWHOOP_REDIRECT_URI="http://localhost:${OMAWHOOP_REDIRECT_PORT}/callback"
readonly WHOOP_AUTH_URL="https://api.prod.whoop.com/oauth/oauth2/auth"
readonly WHOOP_TOKEN_URL="https://api.prod.whoop.com/oauth/oauth2/token"
readonly WHOOP_API_BASE="https://api.prod.whoop.com/developer"
# "offline_access" is rejected outright by WHOOP's Hydra instance as an
# unknown scope; "offline" is what actually gets a refresh_token back
# without it, access_token-only responses expire in ~1hr with no way to
# renew short of a full re-authorization.
readonly WHOOP_SCOPES="read:recovery read:cycles read:sleep read:workout read:profile read:body_measurement offline"

#######################################
# Percent-encodes stdin for an application/x-www-form-urlencoded body.
#######################################
whoop_urlencode() {
  jq -sRr @uri
}

#######################################
# POSTs a form to a URL. The body is piped to curl on stdin, so the client
# secret, auth code and refresh token never appear in argv (visible to other
# processes through `ps` and /proc/<pid>/cmdline).
# Arguments:
#   URL, then NAME VALUE pairs.
# Outputs:
#   Response body, a newline, then the HTTP status code.
#######################################
whoop_post_form() {
  local url="$1" body="" sep=""
  shift
  while (($#)); do
    body+="${sep}$1=$(printf '%s' "$2" | whoop_urlencode)"
    sep="&"
    shift 2
  done
  printf '%s' "$body" | curl -sS -w '\n%{http_code}' -X POST --data-binary @- "$url"
}

#######################################
# Sends a request with a bearer token. The Authorization header is read by
# curl from stdin (-H @-) so the token stays out of argv.
# Arguments:
#   Bearer token, HTTP method, URL.
# Outputs:
#   Response body, a newline, then the HTTP status code.
#######################################
whoop_authed_request() {
  local token="$1" method="$2" url="$3"
  printf 'Authorization: Bearer %s\n' "$token" |
    curl -sS -w '\n%{http_code}' -X "$method" -H @- "$url"
}

#######################################
# Reduces an OAuth error response to its error fields. Never echo a raw
# token-endpoint response: a success body carries live tokens.
# Arguments:
#   Response body.
#######################################
whoop_error_summary() {
  local out
  out=$(jq -r '[.error, .error_description] | map(select(type == "string")) | join(": ")' <<< "$1" 2>/dev/null) || out=""
  echo "${out:-no error detail}"
}

#######################################
# Loads CLIENT_ID / CLIENT_SECRET from disk into the current shell.
# Globals:
#   OMAWHOOP_CONFIG_FILE
# Returns:
#   1 if no config file exists or it's missing either value.
#######################################
whoop_load_config() {
  [[ -f "$OMAWHOOP_CONFIG_FILE" ]] || return 1
  # shellcheck disable=SC1090
  source "$OMAWHOOP_CONFIG_FILE"
  [[ -n "${CLIENT_ID:-}" && -n "${CLIENT_SECRET:-}" ]]
}

#######################################
# Persists an access/refresh token pair to disk, 0600.
# Globals:
#   OMAWHOOP_STATE_DIR, OMAWHOOP_TOKENS_FILE
# Arguments:
#   Access token, refresh token, seconds until expiry.
#######################################
whoop_save_tokens() {
  local access="$1" refresh="$2" expires_in="$3"
  mkdir -p "$OMAWHOOP_STATE_DIR"
  chmod 700 "$OMAWHOOP_STATE_DIR"

  local now
  now=$(date +%s)
  # 30s safety margin so a token never gets used right as it expires.
  local expires_at=$(( now + expires_in - 30 ))

  jq -n --arg a "$access" --arg r "$refresh" --argjson e "$expires_at" \
    '{access_token: $a, refresh_token: $r, expires_at: $e}' > "$OMAWHOOP_TOKENS_FILE"
  chmod 600 "$OMAWHOOP_TOKENS_FILE"
}

#######################################
# Prints a valid access token to stdout, refreshing it first if it's
# expired or about to be.
# Globals:
#   OMAWHOOP_TOKENS_FILE, WHOOP_TOKEN_URL, CLIENT_ID, CLIENT_SECRET
# Returns:
#   1 (no output) if there's nothing usable to refresh.
#######################################
whoop_ensure_token() {
  [[ -f "$OMAWHOOP_TOKENS_FILE" ]] || return 1
  whoop_load_config || return 1

  local access refresh expires_at now
  access=$(jq -r '.access_token // empty' "$OMAWHOOP_TOKENS_FILE")
  refresh=$(jq -r '.refresh_token // empty' "$OMAWHOOP_TOKENS_FILE")
  expires_at=$(jq -r '.expires_at // 0' "$OMAWHOOP_TOKENS_FILE")
  now=$(date +%s)

  if [[ -n "$access" && "$now" -lt "$expires_at" ]]; then
    echo "$access"
    return 0
  fi

  [[ -n "$refresh" ]] || return 1

  local resp_raw http_status resp
  resp_raw=$(whoop_post_form "$WHOOP_TOKEN_URL" \
    grant_type refresh_token \
    refresh_token "$refresh" \
    client_id "$CLIENT_ID" \
    client_secret "$CLIENT_SECRET") || return 1
  http_status="${resp_raw##*$'\n'}"
  resp="${resp_raw%$'\n'*}"
  [[ "$http_status" == 2* ]] || {
    echo "Token refresh failed (HTTP $http_status): $(whoop_error_summary "$resp")" >&2
    return 1
  }

  access=$(jq -r '.access_token // empty' <<< "$resp")
  [[ -n "$access" ]] || return 1
  local new_refresh expires_in
  new_refresh=$(jq -r '.refresh_token // empty' <<< "$resp")
  expires_in=$(jq -r '.expires_in // 3600' <<< "$resp")

  whoop_save_tokens "$access" "${new_refresh:-$refresh}" "$expires_in"
  echo "$access"
}

#######################################
# Fetches a WHOOP API path with a bearer token, setting $body and $status
# in the caller's scope. Exits the script on a 401 — call it directly,
# never as "$(whoop_api_get ...)", or that exit only kills the subshell.
# Arguments:
#   Bearer token, API path (e.g. "/v2/cycle?limit=1").
#######################################
whoop_api_get() {
  local token="$1" path="$2" raw
  raw=$(whoop_authed_request "$token" GET "$WHOOP_API_BASE$path") || raw=$'\n000'
  status="${raw##*$'\n'}"
  body="${raw%$'\n'*}"
  if [[ "$status" == "401" ]]; then
    echo '{"error":"not_authenticated"}'
    exit 1
  fi
}
