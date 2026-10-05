#!/usr/bin/env bash
# End-to-end walk-through: selective, bounded reads and authorization at every layer.
# Every step asserts its outcome; the script exits non-zero on the first surprise.
# $select, $filter, etc. are literal OData keywords, hence the single quotes.
# shellcheck disable=SC2016
set -euo pipefail
. "$(dirname "$0")/common.sh"
require az terraform docker jq curl

load_outputs
gateway="$(out apim_gateway_url)"
api="$gateway/api"
dab="$(out dab_url)/api"
analyst_a="$(client_token analyst-a)"
catalog="$(client_token catalog)"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

step() { printf '\n== %s\n' "$*"; }
pass() { printf '   ok: %s\n' "$*"; }
fail() { printf '   FAILED: %s\n' "$*" >&2; exit 1; }

# call <token|""> <role|""> <url> [curl query args...]; sets $status and $body.
call() {
  local token=$1 role=$2 url=$3
  shift 3
  local args=(--silent --get --output "$body_file" --write-out '%{http_code}')
  [ -z "$token" ] || args+=(-H "Authorization: Bearer $token")
  [ -z "$role" ] || args+=(-H "X-MS-API-ROLE: $role")
  status="$(curl "${args[@]}" "$@" "$url")"
  body="$(cat "$body_file")"
}

expect() {
  case " $* " in
    *" $status "*) pass "HTTP $status" ;;
    *) fail "expected HTTP $*, got $status: $body" ;;
  esac
}

assert() {
  jq -e "$1" <<<"$body" >/dev/null || fail "$2"
  pass "$2"
}

step "1. No token: APIM rejects the call"
call "" "" "$api/scenes"
expect 401

step "2. analyst-a reads the catalog with explicit fields and sort order"
call "$analyst_a" mission-a-analyst "$api/scenes" \
  --data-urlencode '$select=scene_id,mission_id,acquired_at,cloud_cover_pct' \
  --data-urlencode '$orderby=acquired_at asc,scene_id asc'
expect 200
jq -r '.value[] | "   \(.scene_id)  mission \(.mission_id)  \(.acquired_at)  cloud \(.cloud_cover_pct)%"' <<<"$body"
assert 'all(.value[]; .mission_id == "A") and (.value | length > 0)' "DAB row policy returned Mission A only"
assert '[.value[].scene_id] | index("A-0004") == null' "embargoed A-0004 absent (PostgreSQL RLS)"

step "3. catalog reads both missions, without coordinates"
call "$catalog" catalog-viewer "$api/scenes" --data-urlencode '$orderby=scene_id asc'
expect 200
jq -r '"   fields: \(.value[0] | keys | join(", "))"' <<<"$body"
assert '[.value[].mission_id] | unique == ["A", "B"]' "both missions visible: catalog-viewer has no DAB row policy"
assert 'all(.value[]; has("center_lat") | not)' "coordinates omitted (DAB field permissions)"
assert '[.value[].scene_id] | (index("A-0004") == null and index("B-0004") == null)' \
  "embargoed scenes still absent: PostgreSQL RLS applies whatever DAB allows"

step "4. catalog selects a coordinate: DAB denies the field"
call "$catalog" catalog-viewer "$api/scenes" --data-urlencode '$select=scene_id,center_lat'
expect 403

step "5. catalog reads spectra: DAB denies the entity"
call "$catalog" catalog-viewer "$api/spectra" --data-urlencode "\$filter=scene_id eq 'A-0001'"
expect 403

step "6. analyst-a pages through a bounded spectral window of one scene"
call "$analyst_a" mission-a-analyst "$api/spectra" \
  --data-urlencode '$select=pixel_row,pixel_col,wavelength_nm,reflectance' \
  --data-urlencode "\$filter=scene_id eq 'A-0002' and wavelength_nm ge 650 and wavelength_nm le 900" \
  --data-urlencode '$orderby=pixel_row asc,pixel_col asc,wavelength_nm asc' \
  --data-urlencode '$first=200'
expect 200
page1="$body"
jq -r '"   page 1: \(.value | length) rows, first \(.value[0] | tostring), last \(.value[-1] | tostring)"' <<<"$page1"
assert '(.value | length) == 200 and (.nextLink | type) == "string"' "page bounded at 200 rows with a nextLink"
assert 'all(.value[]; .wavelength_nm >= 650 and .wavelength_nm <= 900)' "filter applied"
next_link="$(jq -r .nextLink <<<"$page1")"
call "$analyst_a" mission-a-analyst "$gateway$next_link"
expect 200
jq -r '"   page 2: \(.value | length) rows, first \(.value[0] | tostring)"' <<<"$body"
key='[.pixel_row, .pixel_col, .wavelength_nm]'
jq -e --argjson page1 "$page1" "(\$page1.value[-1] | $key) < (.value[0] | $key)" <<<"$body" >/dev/null ||
  fail "page 2 does not continue after page 1"
pass "page 2 continues exactly after page 1 in the declared sort order"

step "7. Unsupported query shapes: APIM rejects them before DAB"
call "$analyst_a" mission-a-analyst "$api/spectra" --data-urlencode '$first=10'
expect 400
call "$analyst_a" mission-a-analyst "$api/spectra" \
  --data-urlencode "\$filter=scene_id eq 'A-0001' or scene_id eq 'A-0002'"
expect 400
call "$analyst_a" mission-a-analyst "$api/scenes" --data-urlencode '$first=5000'
expect 400
call "$analyst_a" mission-a-analyst "$api/scenes" --data-urlencode '$count=true'
expect 400

step "8. analyst-a asks for a Mission B scene: the DAB policy becomes a SQL predicate"
call "$analyst_a" mission-a-analyst "$api/scenes" --data-urlencode "\$filter=scene_id eq 'B-0001'"
expect 200
assert '.value == []' "no rows: mission_id = 'A' was added to the query"

step "9. Role spoofing and APIM bypass"
call "$analyst_a" mission-b-analyst "$api/scenes"
expect 403
pass "APIM: mission-b-analyst is not in analyst-a's token"
call "$analyst_a" mission-b-analyst "$dab/scenes"
expect 403
pass "DAB directly: same answer without APIM"
call "" "" "$dab/scenes"
expect 403
pass "DAB directly without a token: anonymous has no permissions"
call "$analyst_a" mission-a-analyst "$dab/scenes"
expect 200
assert 'all(.value[]; .mission_id == "A")' "DAB directly with a valid token still applies the row policy"

step "10. Writes are not part of the contract"
status="$(curl --silent --output /dev/null --write-out '%{http_code}' --request POST \
  -H "Authorization: Bearer $analyst_a" -H 'X-MS-API-ROLE: mission-a-analyst' \
  -H 'Content-Type: application/json' --data '{"scene_id":"A-0009"}' "$api/scenes")"
expect 404 405
pass "APIM declares GET operations only"
status="$(curl --silent --output /dev/null --write-out '%{http_code}' --request POST \
  -H "Authorization: Bearer $analyst_a" -H 'X-MS-API-ROLE: mission-a-analyst' \
  -H 'Content-Type: application/json' --data '{"scene_id":"A-0009"}' "$dab/scenes")"
expect 403
pass "DAB grants read only"

step "11. PostgreSQL floor, checked as the API's database role"
pg "$(out database_name)" <"$repo_root/sql/50-assertions.sql"

printf '\nAll checks passed.\n'
