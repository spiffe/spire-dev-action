#!/usr/bin/env bash
# Registration entry rendering.
#
# One canonical entry schema in, three representations out:
#
#   1. spire-server CLI JSON  -- for `spire-server entry create -data`, used when
#      the controller-manager is disabled.
#   2. ClusterStaticEntry YAML -- dropped into the controller-manager's
#      staticManifestPath (host mode).
#   3. helm values YAML       -- spire-server.controllerManager.identities.
#      clusterStaticEntries (k8s mode).
#
# Having a single canonical form is what lets `controller-manager: false` work:
# the same entries the controller-manager would have created are instead handed
# straight to the spire-server CLI.
#
# This file is pure text transformation. It needs no cluster, no root and no
# SPIRE, which is why it has golden-file tests under tests/entries.

[ -n "${_SPIRE_DEV_ENTRIES_SH:-}" ] && return 0
_SPIRE_DEV_ENTRIES_SH=1

_entries_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "${_entries_lib_dir}/common.sh"

# The trust domain placeholder left in ClusterStaticEntry manifests. The
# controller-manager is configured with expandEnvStaticManifests: true and
# systemd supplies SPIFFE_TRUST_DOMAIN, so manifests stay readable and the trust
# domain has exactly one source of truth.
export ENTRIES_TRUST_DOMAIN_PLACEHOLDER='${SPIFFE_TRUST_DOMAIN}'

# jq program shared by every emitter: validates and normalizes the canonical
# schema. Takes $td (trust domain or placeholder) and $parent (default parent ID).
_entries_normalize_jq='
def as_list: if . == null then [] elif type == "array" then . else [.] end;

def qualify($td):
  if . == null or . == "" then null
  elif startswith("spiffe://") then .
  elif startswith("/") then "spiffe://" + $td + .
  else "spiffe://" + $td + "/" + .
  end;

# A selector is "type:value", split on the first colon only: values such as
# id:foo.service and namespace:default contain colons of their own.
def selector:
  if type == "object" then
    { type: (.type // ""), value: (.value // "") }
  elif type == "string" then
    (index(":")) as $i
    | if $i == null then
        error("selector \"" + . + "\" is not in type:value form")
      else
        { type: .[0:$i], value: .[$i+1:] }
      end
  else
    error("selector must be a string or an object with type and value")
  end;

# Derived from the SPIFFE ID path so entries need no explicit name, and safe to
# use as a Kubernetes object name and a helm values key.
def derive_name:
  sub("^spiffe://[^/]*/?"; "")
  | ascii_downcase
  | gsub("[^a-z0-9]+"; "-")
  | sub("^-+"; "")
  | sub("-+$"; "")
  | if . == "" then "entry" else . end;

if type != "array" then
  error("entries must be a list, got " + (type))
else . end
| to_entries
| map(
    .key as $index
    | .value
    | if type != "object" then
        error("entry \($index) must be a mapping, got " + (type))
      else . end
    | (.spiffeID // .spiffeId // .spiffe_id) as $rawID
    | if ($rawID // "") == "" then
        error("entry \($index) is missing spiffeID")
      else . end
    | ($rawID | qualify($td)) as $spiffeID
    | ((.parentID // .parentId // .parent_id) | qualify($td)) as $parentID
    | ((.selectors // []) | as_list) as $rawSelectors
    | if ($rawSelectors | length) == 0 then
        error("entry \($index) (\($spiffeID)) has no selectors")
      else . end
    | {
        name: ((.name // "") | if . == "" then ($spiffeID | derive_name) else . end),
        spiffeID: $spiffeID,
        parentID: ($parentID // $parent),
        selectors: ($rawSelectors | map(selector)),
        dnsNames: ((.dnsNames // .dns_names) | as_list),
        federatesWith: ((.federatesWith // .federates_with) | as_list),
        admin: ((.admin // false) | if type == "string" then . == "true" else . end),
        downstream: ((.downstream // false) | if type == "string" then . == "true" else . end),
        storeSVID: ((.storeSVID // .storeSvid // .store_svid // false) | if type == "string" then . == "true" else . end),
        x509SVIDTTL: ((.x509SVIDTTL // .x509SvidTtl // .x509_svid_ttl // 0) | tonumber),
        jwtSVIDTTL: ((.jwtSVIDTTL // .jwtSvidTtl // .jwt_svid_ttl // 0) | tonumber),
        hint: (.hint // "")
      }
  )
'

# entries_normalize <input-file> <trust-domain> <default-parent-id>
#
# Reads YAML or JSON and echoes the canonical JSON array. Fails with a message
# naming the offending entry rather than emitting something SPIRE will reject
# later.
entries_normalize() {
  local input="$1"
  local trust_domain="$2"
  local default_parent="${3:-}"

  require_cmd yq jq
  [ -f "${input}" ] || log_fail "entries file not found: ${input}"

  local json
  # yq reads JSON as well as YAML, so callers need not care which they have.
  json="$(yq -o=json -I=0 '.' "${input}" 2>&1)" ||
    log_fail "could not parse entries as YAML or JSON: ${json}"

  # An empty document is not an error: it means "deploy SPIRE, no entries".
  if [ -z "${json}" ] || [ "${json}" = "null" ]; then
    echo '[]'
    return 0
  fi

  local out
  if ! out="$(printf '%s' "${json}" | jq -e \
    --arg td "${trust_domain}" \
    --arg parent "${default_parent}" \
    "${_entries_normalize_jq}" 2>&1)"; then
    log_fail "invalid entries: ${out#jq: error*: }"
  fi
  printf '%s\n' "${out}"
}

# entries_to_server_json <canonical-json> <out-file>
#
# Emits common.RegistrationEntries, the format accepted by
# `spire-server entry create -data`. Field names and shapes are per
# proto/spire/common/common.pb.go: flat string IDs, snake_case keys, and
# selectors as {type, value} objects. Zero-valued optional fields are omitted so
# the file stays readable.
entries_to_server_json() {
  local canonical="$1"
  local out_file="$2"
  require_cmd jq

  printf '%s' "${canonical}" | jq '{
    entries: map(
      {
        spiffe_id: .spiffeID,
        parent_id: .parentID,
        selectors: .selectors
      }
      + (if (.dnsNames | length) > 0 then {dns_names: .dnsNames} else {} end)
      + (if (.federatesWith | length) > 0 then {federates_with: .federatesWith} else {} end)
      + (if .admin then {admin: true} else {} end)
      + (if .downstream then {downstream: true} else {} end)
      + (if .storeSVID then {store_svid: true} else {} end)
      + (if .x509SVIDTTL > 0 then {x509_svid_ttl: .x509SVIDTTL} else {} end)
      + (if .jwtSVIDTTL > 0 then {jwt_svid_ttl: .jwtSVIDTTL} else {} end)
      + (if .hint != "" then {hint: .hint} else {} end)
    )
  }' >"${out_file}"
}

# entries_to_static_manifests <canonical-json> <out-dir>
#
# One ClusterStaticEntry document per entry, named <name>.yaml. The
# controller-manager watches the directory, so file-per-entry keeps a later run
# able to replace a single entry.
entries_to_static_manifests() {
  local canonical="$1"
  local out_dir="$2"
  require_cmd jq yq

  mkdir -p "${out_dir}"

  local count
  count="$(printf '%s' "${canonical}" | jq 'length')"
  local i name
  for ((i = 0; i < count; i++)); do
    name="$(printf '%s' "${canonical}" | jq -r ".[${i}].name")"
    printf '%s' "${canonical}" | jq ".[${i}]" | _entry_to_static_manifest \
      >"${out_dir}/${name}.yaml"
  done
}

_entry_to_static_manifest() {
  jq '{
    apiVersion: "spire.spiffe.io/v1alpha1",
    kind: "ClusterStaticEntry",
    metadata: {name: .name},
    spec: (
      {
        parentID: .parentID,
        spiffeID: .spiffeID,
        selectors: (.selectors | map(.type + ":" + .value))
      }
      + (if (.dnsNames | length) > 0 then {dnsNames: .dnsNames} else {} end)
      + (if (.federatesWith | length) > 0 then {federatesWith: .federatesWith} else {} end)
      + (if .admin then {admin: true} else {} end)
      + (if .downstream then {downstream: true} else {} end)
      + (if .storeSVID then {storeSVID: true} else {} end)
      # The CRD types both TTLs as duration strings, not integers.
      + (if .x509SVIDTTL > 0 then {x509SVIDTTL: "\(.x509SVIDTTL)s"} else {} end)
      + (if .jwtSVIDTTL > 0 then {jwtSVIDTTL: "\(.jwtSVIDTTL)s"} else {} end)
      + (if .hint != "" then {hint: .hint} else {} end)
    )
  }' | yq -P '.'
}

# Fields the spire chart accepts under clusterStaticEntries. The chart hard-fails
# on anything else (charts/spire-server/templates/controller-manager-static-entries.yaml
# validates each key against this list), and it is a strict subset of the
# ClusterStaticEntry CRD: notably storeSVID is absent.
ENTRIES_HELM_SUPPORTED_FIELDS="admin dnsNames downstream federatesWith hint jwtSVIDTTL parentID selectors spiffeID x509SVIDTTL"

# entries_assert_helm_supported <canonical-json>
#
# Fails when an entry uses a field the chart cannot express, rather than dropping
# it silently and leaving the caller with an entry that does not behave as
# written.
entries_assert_helm_supported() {
  local canonical="$1"
  require_cmd jq

  local offending
  offending="$(printf '%s' "${canonical}" | jq -r '
    .[]
    | . as $e
    | [ (if .storeSVID then "storeSVID" else empty end) ] as $unsupported
    | select(($unsupported | length) > 0)
    | "  \($e.name): \($unsupported | join(", "))"
  ')"

  if [ -n "${offending}" ]; then
    log_error "these entries use fields the spire helm chart cannot express:"
    printf '%s\n' "${offending}" >&2
    log_fail "the chart supports only: ${ENTRIES_HELM_SUPPORTED_FIELDS}. Remove the field, or use host mode where the full ClusterStaticEntry CRD is available."
  fi
}

# entries_to_helm_values <canonical-json> <out-file> [values-key]
#
# Emits a values file setting clusterStaticEntries. A values file rather than
# --set arguments: entry names, SPIFFE IDs and selectors all contain characters
# that helm's --set parser treats as structure (dots, commas, equals), and
# escaping them correctly for every field is more fragile than composing YAML.
#
# Chart values rather than kubectl-applied CRs because the chart defaults to
# watchClassless: false with className auto-set to <namespace>-<release>, so a
# classless CR applied out of band would simply be ignored. Going through values
# also makes the entries part of the release, so they are removed with it.
entries_to_helm_values() {
  local canonical="$1"
  local out_file="$2"
  local values_key="${3:-spire-server}"
  require_cmd jq yq

  entries_assert_helm_supported "${canonical}"

  printf '%s' "${canonical}" | jq \
    --arg key "${values_key}" '
    {
      ($key): {
        controllerManager: {
          identities: {
            clusterStaticEntries: (
              map({
                key: .name,
                value: (
                  {
                    parentID: .parentID,
                    spiffeID: .spiffeID,
                    selectors: (.selectors | map(.type + ":" + .value))
                  }
                  + (if (.dnsNames | length) > 0 then {dnsNames: .dnsNames} else {} end)
                  + (if (.federatesWith | length) > 0 then {federatesWith: .federatesWith} else {} end)
                  + (if .admin then {admin: true} else {} end)
                  + (if .downstream then {downstream: true} else {} end)
                  + (if .x509SVIDTTL > 0 then {x509SVIDTTL: "\(.x509SVIDTTL)s"} else {} end)
                  + (if .jwtSVIDTTL > 0 then {jwtSVIDTTL: "\(.jwtSVIDTTL)s"} else {} end)
                  + (if .hint != "" then {hint: .hint} else {} end)
                )
              })
              | from_entries
            )
          }
        }
      }
    }' | yq -P '.' >"${out_file}"
}

# entries_summary <canonical-json> — one line per entry, for the run log.
entries_summary() {
  printf '%s' "$1" | jq -r '.[] |
    "  \(.name): \(.spiffeID) parent=\(.parentID) selectors=[\(.selectors | map(.type + ":" + .value) | join(", "))]"'
}

# entries_collect <inline-yaml> <entries-file> <out-file>
#
# Combines the two ways a caller can supply entries into one file. Both may be
# given; inline entries come first.
entries_collect() {
  local inline="$1"
  local file="$2"
  local out_file="$3"

  require_cmd yq

  local inline_file="${out_file}.inline"
  local named_file="${out_file}.named"
  printf '%s\n' "${inline}" >"${inline_file}"
  if [ -n "${file}" ]; then
    [ -f "${file}" ] || log_fail "entries-file not found: ${file}"
    cp "${file}" "${named_file}"
  else
    : >"${named_file}"
  fi

  # Merged with yq rather than concatenated: a document separator or differing
  # indentation between the two sources would make plain concatenation produce
  # something that is not one sequence.
  yq ea -o=json -I=0 '[.] | flatten | map(select(. != null))' \
    "${inline_file}" "${named_file}" >"${out_file}" ||
    log_fail "could not combine the entries and entries-file inputs"
  rm -f "${inline_file}" "${named_file}"
}
