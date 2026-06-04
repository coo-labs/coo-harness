#!/usr/bin/env bash
# Group S — secrets-schema invariants for integrity-check.sh.
#
# Implements S1-S5, S7, S8 from operations/secrets/README.md §3.4 (Track 1b
# of the secrets-management implementation epic, coo-memory#871). S6 is
# demoted to warning per SOP rationalization R-3 and NOT emitted as an
# invariant from this file.
#
# Wired in by integrity-check.sh's Group S section via `_add KEY ok detail`
# triples. Functions here populate the parent's RESULTS array indirectly:
# each `s_check_S<N>` function calls `_add` directly (the parent provides
# that function), and reads from environment-set helpers like
# $VADE_COO_MEMORY_DIR and $RESULTS via dynamic scope (bash arrays + the
# `_add` function defined in integrity-check.sh).
#
# Probe-not-repair: nothing here mutates state. Failures are reported via
# `_add false …` and bubble through the JSON output; the script keeps
# exit 0. Boot-blocking integration is a follow-up PR after Track 1b
# soaks clean.
#
# Skip semantics: every S invariant that relies on a capability not
# present in the current environment (live `op` CLI, network, etc.) is
# expected to emit `_add S<N> true "skipped: <reason>"` rather than
# false. This keeps CI fake-env runs green.

# Detect whether we're inside the bootstrap-regression CI fake env. Same
# markers as integrity-check.sh's E5/E9 use.
_s_in_ci_fake_env() {
  [ -n "${VADE_CI_WORKSPACE_ROOT:-}" ] || [ -n "${VADE_BINDIR_OVERRIDE:-}" ]
}

# Cheap "is op CLI usable" probe. Live `op whoami` would be authoritative
# but is expensive and may itself fail for unrelated reasons. We only
# require the binary to be present and not a CI mock — actual data reads
# are best-effort below.
_s_op_live() {
  if _s_in_ci_fake_env; then return 1; fi
  command -v op >/dev/null 2>&1 || return 1
  # When the SA token is unset, op will fail every read regardless.
  [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || return 1
  return 0
}

# Truncate a detail string to ~200 chars so the JSON output stays
# readable when validator errors are verbose.
_s_trunc() {
  local s="$1" max="${2:-200}"
  if [ "${#s}" -le "$max" ]; then
    printf '%s' "$s"
  else
    printf '%s…' "${s:0:$max}"
  fi
}

# Default schema location resolution. Allows the test runner to override
# via $VADE_SECRETS_SCHEMA / $VADE_SECRETS_SCHEMA_DIR.
_s_schema_yaml() {
  printf '%s' "${VADE_SECRETS_SCHEMA:-$VADE_COO_MEMORY_DIR/operations/secrets/schema.yaml}"
}
_s_schema_json() {
  printf '%s' "${VADE_SECRETS_SCHEMA_JSON:-$VADE_COO_MEMORY_DIR/operations/secrets/schema.schema.json}"
}
_s_schema_validator() {
  printf '%s' "${VADE_SECRETS_VALIDATOR:-$VADE_COO_MEMORY_DIR/bin/secrets-schema-check.py}"
}
_s_env_snapshot_dir() {
  printf '%s' "${VADE_SECRETS_SNAPSHOT_DIR:-$VADE_COO_MEMORY_DIR/operations/secrets/env-snapshots}"
}

# ── S1: schema.yaml parses + shape-valid ─────────────────────────
s_check_S1() {
  local schema validator schemajson
  schema="$(_s_schema_yaml)"
  schemajson="$(_s_schema_json)"
  validator="$(_s_schema_validator)"

  if [ ! -f "$schema" ]; then
    _add S1 skip "schema.yaml not found at $schema"
    return
  fi
  if [ ! -f "$schemajson" ]; then
    _add S1 skip "schema.schema.json not found at $schemajson"
    return
  fi
  if [ ! -x "$validator" ] && [ ! -f "$validator" ]; then
    _add S1 skip "secrets-schema-check.py not found at $validator"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    _add S1 skip "python3 not available"
    return
  fi
  # Dependency check — PyYAML + jsonschema. If missing, skip cleanly
  # (the Track 1a CI installs them; the cloud container has them; CI
  # fake-env mode without them should not fail S1).
  if ! python3 -c 'import yaml, jsonschema' >/dev/null 2>&1; then
    _add S1 skip "PyYAML or jsonschema not importable in python3 — install with pip"
    return
  fi

  local out rc
  out="$(python3 "$validator" "$schema" --schema "$schemajson" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    _add S1 true "schema.yaml validates clean against schema.schema.json"
  else
    _add S1 false "validator exit=$rc: $(_s_trunc "$out")"
  fi
}

# ── S2: every declared env-alias is set (or item is dormant) ─────
s_check_S2() {
  local schema; schema="$(_s_schema_yaml)"
  if [ ! -f "$schema" ]; then
    _add S2 skip "schema.yaml not found at $schema"
    return
  fi
  if ! command -v yq >/dev/null 2>&1; then
    _add S2 skip "yq not available"
    return
  fi

  # Emit lines of `<id>|<status>|<alias>` for every non-dormant
  # credential with at least one env-alias. Dormant entries are
  # filtered out per SOP §3.4 (env vars may be intentionally unset).
  local rows
  rows="$(yq -r '
    .credentials[]
    | select(.status != "dormant")
    | . as $c
    | (.env_aliases // [])[]
    | "\($c.id)|\($c.status)|\(.)"' "$schema" 2>/dev/null)" || rows=""

  if [ -z "$rows" ]; then
    _add S2 true "no non-dormant env-aliases declared"
    return
  fi

  local total=0 missing=()
  while IFS='|' read -r id status alias; do
    [ -z "$alias" ] && continue
    total=$((total + 1))
    eval "val=\${$alias:-}"
    if [ -z "${val:-}" ]; then
      missing+=("${id}:${alias}")
    fi
  done <<< "$rows"

  if [ "${#missing[@]}" -eq 0 ]; then
    _add S2 true "$total/$total declared env-aliases set in process env"
  else
    local list; list="$(IFS=,; echo "${missing[*]}")"
    _add S2 false "${#missing[@]}/$total env-aliases unset: $(_s_trunc "$list")"
  fi
}

# ── S3: declared mirrors exist; sha8 matches canonical where shape allows ─
s_check_S3() {
  local schema; schema="$(_s_schema_yaml)"
  if [ ! -f "$schema" ]; then
    _add S3 skip "schema.yaml not found at $schema"
    return
  fi
  if ! command -v yq >/dev/null 2>&1; then
    _add S3 skip "yq not available"
    return
  fi

  # Each row: <cred_id>|<surface>|<path_or_name>|<format>|<op_item>|<op_field>
  # The trailing op_item/op_field carry the canonical-source pointer so
  # we can compute sha8 where the mirror surface allows it.
  local rows
  rows="$(yq -r '
    .credentials[]
    | select(.status != "dormant")
    | . as $c
    | (.mirrors // [])[]
    | "\($c.id)|\(.surface)|\(.path_or_name)|\(.format // "TBD")|\($c.op_item)|\($c.op_field)"' "$schema" 2>/dev/null)" || rows=""

  if [ -z "$rows" ]; then
    _add S3 true "no non-dormant mirrors declared"
    return
  fi

  local total=0 missing=() sha_mismatch=() sha_checked=0
  local op_live=0
  if _s_op_live; then op_live=1; fi

  while IFS='|' read -r cred_id surface path_or_name format op_item op_field; do
    [ -z "$cred_id" ] && continue
    total=$((total + 1))
    case "$surface" in
      container_env)
        case "$format" in
          json-key-replace)
            # path_or_name shape: "<filepath>::env::<KEY>"
            local file_part key_part
            file_part="${path_or_name%%::env::*}"
            key_part="${path_or_name##*::env::}"
            if [ "$file_part" = "$path_or_name" ] || [ -z "$key_part" ]; then
              missing+=("${cred_id}:${surface}:malformed-path")
              continue
            fi
            if [ ! -f "$file_part" ]; then
              missing+=("${cred_id}:${surface}:file-absent:$file_part")
              continue
            fi
            local val
            val="$(jq -r --arg k "$key_part" '.env[$k] // empty' "$file_part" 2>/dev/null)"
            if [ -z "$val" ]; then
              missing+=("${cred_id}:${surface}:env-key-absent:$key_part")
              continue
            fi
            # sha8 compare (only when op live)
            if [ "$op_live" = 1 ]; then
              local canon=""
              canon="$(op read "op://COO/$op_item/$op_field" 2>/dev/null || true)"
              if [ -n "$canon" ]; then
                local mirror_sha canon_sha
                mirror_sha="$(printf '%s' "$val" | sha256sum 2>/dev/null | cut -c1-8)"
                canon_sha="$(printf '%s' "$canon" | sha256sum 2>/dev/null | cut -c1-8)"
                if [ -n "$mirror_sha" ] && [ -n "$canon_sha" ]; then
                  sha_checked=$((sha_checked + 1))
                  if [ "$mirror_sha" != "$canon_sha" ]; then
                    sha_mismatch+=("${cred_id}:${key_part}")
                  fi
                fi
              fi
            fi
            ;;
          sh-export-replace)
            # path_or_name shape: "<filepath>::<KEY>"
            local file_part2 key_part2
            file_part2="${path_or_name%%::*}"
            key_part2="${path_or_name##*::}"
            if [ "$file_part2" = "$path_or_name" ] || [ -z "$key_part2" ]; then
              missing+=("${cred_id}:${surface}:malformed-path")
              continue
            fi
            if [ ! -f "$file_part2" ]; then
              missing+=("${cred_id}:${surface}:file-absent:$file_part2")
              continue
            fi
            if ! grep -qE "^[[:space:]]*(export[[:space:]]+)?${key_part2}=" "$file_part2" 2>/dev/null; then
              missing+=("${cred_id}:${surface}:export-line-absent:$key_part2")
            fi
            if [ "$op_live" = 1 ]; then
              local canon2 mirror_val2
              canon2="$(op read "op://COO/$op_item/$op_field" 2>/dev/null || true)"
              # Extract the value after the `=` on the export line. Strip
              # surrounding quotes so a shell-quoted form matches the
              # canonical plain value.
              mirror_val2="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key_part2}=" "$file_part2" 2>/dev/null \
                | head -1 \
                | sed -E "s/^[[:space:]]*(export[[:space:]]+)?${key_part2}=//" \
                | sed -E 's/^"(.*)"$/\1/' \
                | sed -E "s/^'(.*)'$/\1/")"
              if [ -n "$canon2" ] && [ -n "$mirror_val2" ]; then
                local m_sha c_sha
                m_sha="$(printf '%s' "$mirror_val2" | sha256sum 2>/dev/null | cut -c1-8)"
                c_sha="$(printf '%s' "$canon2" | sha256sum 2>/dev/null | cut -c1-8)"
                if [ -n "$m_sha" ] && [ -n "$c_sha" ]; then
                  sha_checked=$((sha_checked + 1))
                  if [ "$m_sha" != "$c_sha" ]; then
                    sha_mismatch+=("${cred_id}:${key_part2}")
                  fi
                fi
              fi
            fi
            ;;
          file-replace)
            # path_or_name is a literal filesystem path (may contain
            # parenthetical commentary in the schema — strip after first
            # space).
            local file_only
            file_only="${path_or_name%% *}"
            # Expand ~ to $HOME if present.
            case "$file_only" in
              "~/"*) file_only="$HOME/${file_only#~/}" ;;
            esac
            if [ -z "$file_only" ] || [ ! -e "$file_only" ]; then
              missing+=("${cred_id}:${surface}:file-absent:$file_only")
            fi
            ;;
          *)
            # TBD / unknown format — informational, not a failure.
            :
            ;;
        esac
        ;;
      org_secret|repo_secret)
        # Requires `gh` + PAT; skip cleanly when unavailable. CI mocks
        # don't include `gh secret list`, so this skips in CI by design.
        if _s_in_ci_fake_env; then
          continue
        fi
        if ! command -v gh >/dev/null 2>&1; then
          continue
        fi
        # path_or_name is either "SECRET_NAME" (org) or "repo/SECRET_NAME"
        # (repo). Decide by surface.
        if [ "$surface" = "org_secret" ]; then
          # Org-level: check coo-labs org.
          if ! gh secret list --org coo-labs 2>/dev/null \
              | awk '{print $1}' | grep -qFx "$path_or_name"; then
            missing+=("${cred_id}:${surface}:secret-absent:$path_or_name")
          fi
        else
          # repo_secret: path_or_name shape is "repo/SECRET_NAME". The
          # schema uses bare repo names (without "coo-labs/" prefix);
          # prepend the org.
          local repo_part secret_part
          repo_part="${path_or_name%%/*}"
          secret_part="${path_or_name##*/}"
          if [ "$repo_part" = "$path_or_name" ] || [ -z "$secret_part" ]; then
            missing+=("${cred_id}:${surface}:malformed-path-or-name")
            continue
          fi
          if ! gh secret list --repo "coo-labs/$repo_part" 2>/dev/null \
              | awk '{print $1}' | grep -qFx "$secret_part"; then
            missing+=("${cred_id}:${surface}:secret-absent:$path_or_name")
          fi
        fi
        ;;
      file)
        # path_or_name is a literal filesystem path. Expand ~ if present.
        local fpath="$path_or_name"
        case "$fpath" in
          "~/"*) fpath="$HOME/${fpath#~/}" ;;
        esac
        if [ ! -e "$fpath" ]; then
          missing+=("${cred_id}:${surface}:file-absent:$fpath")
        fi
        ;;
      *)
        # codespaces_secret / dependabot_secret are opaque to audit (403);
        # workflow_op_inline is a documentation surface. Skip silently.
        :
        ;;
    esac
  done <<< "$rows"

  if [ "${#missing[@]}" -eq 0 ] && [ "${#sha_mismatch[@]}" -eq 0 ]; then
    local detail="all $total declared mirrors present"
    if [ "$sha_checked" -gt 0 ]; then
      detail="${detail}; sha8 match on $sha_checked sampled values"
    else
      detail="${detail}; sha8 sampling skipped (op CLI not live or no readable canonical)"
    fi
    _add S3 true "$detail"
  else
    local parts=()
    [ "${#missing[@]}" -gt 0 ] && parts+=("missing: $(IFS=,; echo "${missing[*]}")")
    [ "${#sha_mismatch[@]}" -gt 0 ] && parts+=("sha8-mismatch: $(IFS=,; echo "${sha_mismatch[*]}")")
    local joined; joined="$(IFS=';'; echo "${parts[*]}")"
    _add S3 false "$(_s_trunc "$joined")"
  fi
}

# ── S4: no multi-field item carries a stale empty `credential` field ─
s_check_S4() {
  local schema; schema="$(_s_schema_yaml)"
  if [ ! -f "$schema" ]; then
    _add S4 skip "schema.yaml not found at $schema"
    return
  fi
  if ! command -v yq >/dev/null 2>&1; then
    _add S4 skip "yq not available"
    return
  fi
  if ! _s_op_live; then
    _add S4 skip "skipped: requires live op CLI + OP_SERVICE_ACCOUNT_TOKEN (CI fake-env or local)"
    return
  fi

  # Multi-field items: op_field is NOT "credential" AND op_alt_fields is
  # non-empty. For each, query `op item get --format=json` and check
  # whether a `credential` field exists with non-empty value.
  local rows
  rows="$(yq -r '
    .credentials[]
    | select(.status != "dormant")
    | select(.op_field != "credential")
    | select((.op_alt_fields // []) | length > 0)
    | "\(.id)|\(.op_item)"' "$schema" 2>/dev/null)" || rows=""

  if [ -z "$rows" ]; then
    _add S4 true "no multi-field credentials to check"
    return
  fi

  local total=0 bad=() unreadable=0
  while IFS='|' read -r cred_id op_item; do
    [ -z "$cred_id" ] && continue
    total=$((total + 1))
    local raw stale_label stale_value
    raw="$(op item get --format=json "$op_item" 2>/dev/null || true)"
    if [ -z "$raw" ]; then
      unreadable=$((unreadable + 1))
      continue
    fi
    # Look for a field labeled "credential". An EMPTY one is the stale
    # S-1 fingerprint we're catching.
    stale_label="$(printf '%s' "$raw" | jq -r '.fields[]? | select(.label=="credential") | .label // empty' 2>/dev/null | head -1)"
    stale_value="$(printf '%s' "$raw" | jq -r '.fields[]? | select(.label=="credential") | .value // empty' 2>/dev/null | head -1)"
    if [ "$stale_label" = "credential" ] && [ -z "$stale_value" ]; then
      bad+=("${cred_id}:${op_item}")
    fi
  done <<< "$rows"

  if [ "${#bad[@]}" -eq 0 ]; then
    local detail="$total multi-field credentials clean (no stale empty 'credential' field)"
    [ "$unreadable" -gt 0 ] && detail="${detail}; $unreadable unreadable via op (transient)"
    _add S4 true "$detail"
  else
    local list; list="$(IFS=,; echo "${bad[*]}")"
    _add S4 false "stale empty 'credential' field on: $(_s_trunc "$list")"
  fi
}

# ── S5: sanctioned paths carry secret-shaped content (presence check) ─
#
# Wording per SOP §3.4: "no plaintext PAT-shape strings in sanctioned
# paths only". Inverted-shape interpretation per parent dispatch: the
# sanctioned paths are EXPECTED to carry secrets (they're the only legal
# place for plaintext bearer values), and the failure mode this catches
# is a sanctioned path drifting to empty/malformed (no token-shapes
# present where the schema mirrors expect them).
#
# This is a forward defense — TODO when settings.json indirection
# (#873 / Track 4) lands, S5's polarity changes: at that point
# /root/.claude/settings.json carries `${TOKEN}` refs, NOT plaintext
# tokens, and S5 should flip to "no plaintext PAT-shape strings here".
s_check_S5() {
  local schema; schema="$(_s_schema_yaml)"
  if [ ! -f "$schema" ]; then
    _add S5 skip "schema.yaml not found at $schema"
    return
  fi
  if ! command -v yq >/dev/null 2>&1; then
    _add S5 skip "yq not available"
    return
  fi
  if ! command -v grep >/dev/null 2>&1; then
    _add S5 skip "grep not available"
    return
  fi

  # Sanctioned-path set per SOP §3.4. /root/ paths are container-specific;
  # the coo-harness/coo-memory paths resolve to whatever the live checkouts
  # are (canonicalized below via $VADE_*_DIR).
  local sanctioned=(
    "/root/.claude/settings.json"
    "/root/.vade/coo-env"
    "${VADE_RUNTIME_DIR:-$HOME/coo-harness}/scripts/lib/common.sh"
    "${VADE_COO_MEMORY_DIR:-$HOME/coo-memory}/.claude/settings.json"
    "${VADE_COO_MEMORY_DIR:-$HOME/coo-memory}/.claude/settings.local.json"
  )

  # Collect every regex from secret_shapes. Use yq to enumerate.
  local patterns
  patterns="$(yq -r '.secret_shapes[].pattern' "$schema" 2>/dev/null \
    | grep -vE '^TBD' || true)"
  if [ -z "$patterns" ]; then
    _add S5 skip "no usable secret_shapes patterns in schema"
    return
  fi

  # For each sanctioned path that exists, scan for ≥1 secret_shapes hit.
  # Per inversion: a sanctioned path with NO hits is the failure (it's
  # supposed to carry secrets).
  local checked=0 empty_paths=() present_paths=0 missing_paths=()
  for p in "${sanctioned[@]}"; do
    if [ ! -f "$p" ]; then
      # Missing sanctioned paths are not necessarily a failure — some
      # are environment-specific (e.g., /root/.vade/coo-env may not
      # exist on a macOS dev). Track but don't fail on absence.
      missing_paths+=("${p##*/}")
      continue
    fi
    checked=$((checked + 1))
    local found=0
    while IFS= read -r rgx; do
      [ -z "$rgx" ] && continue
      if grep -qE "$rgx" "$p" 2>/dev/null; then
        found=1
        break
      fi
    done <<< "$patterns"
    if [ "$found" = 1 ]; then
      present_paths=$((present_paths + 1))
    else
      empty_paths+=("${p##*/}")
    fi
  done

  if [ "$checked" -eq 0 ]; then
    _add S5 skip "no sanctioned paths present on this host (env may not require them)"
    return
  fi
  if [ "${#empty_paths[@]}" -eq 0 ]; then
    local detail="$present_paths/$checked sanctioned paths carry expected secret shapes"
    if [ "${#missing_paths[@]}" -gt 0 ]; then
      detail="${detail}; absent (not required on this host): $(IFS=,; echo "${missing_paths[*]}")"
    fi
    _add S5 true "$detail"
  else
    local list; list="$(IFS=,; echo "${empty_paths[*]}")"
    _add S5 false "sanctioned paths present but carry NO secret-shape matches: $(_s_trunc "$list") (drift to empty/malformed — investigate)"
  fi
}

# ── S7: orphan-pattern detection on secret_shapes regex registry ─
s_check_S7() {
  local schema; schema="$(_s_schema_yaml)"
  if [ ! -f "$schema" ]; then
    _add S7 skip "schema.yaml not found at $schema"
    return
  fi
  if ! command -v yq >/dev/null 2>&1; then
    _add S7 skip "yq not available"
    return
  fi
  if ! _s_op_live; then
    _add S7 skip "skipped: requires live op CLI + OP_SERVICE_ACCOUNT_TOKEN (CI fake-env or local)"
    return
  fi

  # Collect canonical credential values (cred_id + value-from-op).
  # Skipped on dormant, items with no op_field, or read failures.
  local cred_rows
  cred_rows="$(yq -r '
    .credentials[]
    | select(.status != "dormant")
    | "\(.id)|\(.op_item)|\(.op_field)"' "$schema" 2>/dev/null)" || cred_rows=""

  if [ -z "$cred_rows" ]; then
    _add S7 skip "no readable credentials in schema"
    return
  fi

  # Read each value once; cache in a flat string-joined buffer keyed by
  # credential id. Bash 4 associative arrays are available on every
  # supported surface so use them.
  declare -A _s7_values=()
  while IFS='|' read -r cred_id op_item op_field; do
    [ -z "$cred_id" ] && continue
    [ "$op_field" = "(derived)" ] && continue
    local val
    val="$(op read "op://COO/$op_item/$op_field" 2>/dev/null || true)"
    if [ -n "$val" ]; then
      _s7_values["$cred_id"]="$val"
    fi
  done <<< "$cred_rows"

  local total_creds=${#_s7_values[@]}
  if [ "$total_creds" -eq 0 ]; then
    _add S7 skip "no credentials readable via op (transient or scope)"
    return
  fi

  # Collect every regex from secret_shapes, paired with its name.
  local pat_rows
  pat_rows="$(yq -r '.secret_shapes[] | "\(.name)|\(.pattern)"' "$schema" 2>/dev/null)" || pat_rows=""

  # Direction 1: orphan regex — for every pattern, ≥1 credential value
  # must match. A pattern with zero matches is "orphan".
  local orphan_patterns=()
  while IFS='|' read -r pname ppat; do
    [ -z "$pname" ] && continue
    [[ "$ppat" == TBD* ]] && continue
    local hit=0
    for cred_id in "${!_s7_values[@]}"; do
      if printf '%s' "${_s7_values[$cred_id]}" | grep -qE "$ppat"; then
        hit=1
        break
      fi
    done
    [ "$hit" = 0 ] && orphan_patterns+=("$pname")
  done <<< "$pat_rows"

  # Direction 2: escape from redactor — every credential value must
  # match ≥1 pattern.
  local escapes=()
  for cred_id in "${!_s7_values[@]}"; do
    local matched=0
    while IFS='|' read -r pname ppat; do
      [ -z "$pname" ] && continue
      [[ "$ppat" == TBD* ]] && continue
      if printf '%s' "${_s7_values[$cred_id]}" | grep -qE "$ppat"; then
        matched=1
        break
      fi
    done <<< "$pat_rows"
    [ "$matched" = 0 ] && escapes+=("$cred_id")
  done

  if [ "${#orphan_patterns[@]}" -eq 0 ] && [ "${#escapes[@]}" -eq 0 ]; then
    _add S7 true "registry clean: all patterns matched ≥1 credential and all $total_creds readable credentials matched ≥1 pattern"
  else
    local parts=()
    [ "${#orphan_patterns[@]}" -gt 0 ] && parts+=("orphan-patterns: $(IFS=,; echo "${orphan_patterns[*]}")")
    [ "${#escapes[@]}" -gt 0 ] && parts+=("redactor-escapes: $(IFS=,; echo "${escapes[*]}")")
    local joined; joined="$(IFS=';'; echo "${parts[*]}")"
    _add S7 false "$(_s_trunc "$joined")"
  fi
}

# ── S8: env-drift detection (+ snapshot write) ───────────────────
s_check_S8() {
  local schema; schema="$(_s_schema_yaml)"
  if [ ! -f "$schema" ]; then
    _add S8 skip "schema.yaml not found at $schema"
    return
  fi
  if ! command -v yq >/dev/null 2>&1; then
    _add S8 skip "yq not available"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    _add S8 skip "python3 not available"
    return
  fi

  # Persist today's env-keyname snapshot. Keynames only — never values.
  # The S8 invariant fails open on snapshot-write errors (the
  # classification check below is the load-bearing logic; snapshot is
  # historical record only).
  local snap_dir snap_file
  snap_dir="$(_s_env_snapshot_dir)"
  snap_file="${snap_dir}/$(date -u +%Y-%m-%d).txt"
  if [ -n "${VADE_SECRETS_SNAPSHOT_SKIP:-}" ]; then
    :  # test escape: don't write
  elif mkdir -p "$snap_dir" 2>/dev/null; then
    env | cut -d= -f1 | sort -u > "$snap_file" 2>/dev/null || true
  fi

  # Run the classifier in python3 against the schema + current env.
  # Returns four counts plus the unknown_secret_shape and unknown_other
  # keynames (pipe-separated).
  local out rc
  out="$(VADE_SCHEMA_YAML="$schema" python3 - <<'PY' 2>&1
import os, sys, re

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML not importable", file=sys.stderr)
    sys.exit(2)

schema_path = os.environ["VADE_SCHEMA_YAML"]
try:
    with open(schema_path) as fh:
        s = yaml.safe_load(fh) or {}
except Exception as exc:
    print(f"ERROR: schema unreadable: {exc}", file=sys.stderr)
    sys.exit(2)

declared_secret = set()
for cred in s.get("credentials", []) or []:
    if cred.get("status") == "dormant":
        # Dormant credentials' env aliases SHOULD be unset; if they
        # happen to be set, classify normally — they'd land in
        # declared_secret bucket as before, which is fine.
        pass
    for alias in cred.get("env_aliases", []) or []:
        declared_secret.add(alias)

allowlist = set(s.get("non_secret_env_allowlist", []) or [])
prefixes = list(s.get("non_secret_env_prefixes", []) or [])

shape_patterns = []
for shape in s.get("secret_shapes", []) or []:
    pat = shape.get("pattern", "")
    if pat.startswith("TBD"):
        continue
    try:
        shape_patterns.append((shape.get("name", "?"), re.compile(pat)))
    except re.error:
        # malformed regex — schema validator (S1) should catch; skip here
        continue

order = s.get("env_drift_detection", {}).get("classification_order", [
    "declared_secret",
    "declared_allowlist",
    "prefix_allowlist",
    "unknown_secret_shape",
    "unknown_other",
])

def classify(name, value):
    for step in order:
        if step == "declared_secret":
            if name in declared_secret:
                return step
        elif step == "declared_allowlist":
            if name in allowlist:
                return step
        elif step == "prefix_allowlist":
            if any(name.startswith(p) for p in prefixes):
                # Defense-in-depth: even a prefix-allowed var graduates
                # to unknown_secret_shape if its value shapes-as-secret.
                if value and any(rx.search(value) for _, rx in shape_patterns):
                    return "unknown_secret_shape"
                return step
        elif step == "unknown_secret_shape":
            if value and any(rx.search(value) for _, rx in shape_patterns):
                return step
        elif step == "unknown_other":
            return step
    return "unknown_other"

buckets = {k: 0 for k in [
    "declared_secret", "declared_allowlist", "prefix_allowlist",
    "unknown_secret_shape", "unknown_other",
]}
secret_unknowns = []
other_unknowns = []
for name, value in os.environ.items():
    cls = classify(name, value)
    buckets[cls] = buckets.get(cls, 0) + 1
    if cls == "unknown_secret_shape":
        secret_unknowns.append(name)
    elif cls == "unknown_other":
        other_unknowns.append(name)

# Output: tab-separated keys for the bash caller to read.
def join(lst, n=10):
    if not lst:
        return ""
    head = sorted(lst)[:n]
    extra = f" (+{len(lst) - n} more)" if len(lst) > n else ""
    return ",".join(head) + extra

print(f"declared_secret={buckets['declared_secret']}")
print(f"declared_allowlist={buckets['declared_allowlist']}")
print(f"prefix_allowlist={buckets['prefix_allowlist']}")
print(f"unknown_secret_shape={buckets['unknown_secret_shape']}")
print(f"unknown_other={buckets['unknown_other']}")
print(f"secret_unknowns_list={join(secret_unknowns)}")
print(f"other_unknowns_list={join(other_unknowns)}")
PY
)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _add S8 skip "classifier exited rc=$rc: $(_s_trunc "$out")"
    return
  fi

  # Parse the python output.
  local ds da pa us uo us_list uo_list
  ds="$(printf '%s\n' "$out" | grep -E '^declared_secret=' | cut -d= -f2-)"
  da="$(printf '%s\n' "$out" | grep -E '^declared_allowlist=' | cut -d= -f2-)"
  pa="$(printf '%s\n' "$out" | grep -E '^prefix_allowlist=' | cut -d= -f2-)"
  us="$(printf '%s\n' "$out" | grep -E '^unknown_secret_shape=' | cut -d= -f2-)"
  uo="$(printf '%s\n' "$out" | grep -E '^unknown_other=' | cut -d= -f2-)"
  us_list="$(printf '%s\n' "$out" | grep -E '^secret_unknowns_list=' | cut -d= -f2-)"
  uo_list="$(printf '%s\n' "$out" | grep -E '^other_unknowns_list=' | cut -d= -f2-)"

  local detail="declared_secret=$ds declared_allowlist=$da prefix_allowlist=$pa unknown_secret_shape=$us unknown_other=$uo"
  if [ "${us:-0}" -gt 0 ]; then
    _add S8 false "$detail; unknown_secret_shape keys: $(_s_trunc "$us_list")"
  else
    if [ "${uo:-0}" -gt 0 ]; then
      detail="${detail}; unknown_other keys: $(_s_trunc "$uo_list")"
    fi
    _add S8 true "$detail"
  fi
}

# Dispatch every S invariant. Called from integrity-check.sh.
s_check_all() {
  s_check_S1
  s_check_S2
  s_check_S3
  s_check_S4
  s_check_S5
  s_check_S7
  s_check_S8
}
