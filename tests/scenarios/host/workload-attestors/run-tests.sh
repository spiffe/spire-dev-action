#!/usr/bin/env bash
# Host mode with extra agent workload attestors.
#
# The agent config hardcoded systemd and unix, so a consumer needing anything else
# -- the slurm attestor, say, for a job on an HPC node -- had no way to turn it on.
# The workload-attestors input names an attestor that takes no configuration; the
# agent-extra-plugins input takes raw HCL for one that does.
#
# The real assertion is that the agent comes up healthy with the extra attestor
# configured. SPIRE refuses to start on a plugin name it does not recognise, so a
# healthy agent proves both that the generated HCL parses and that the plugin
# actually resolved -- neither of which the config tests can show on their own.
#
# What this cannot prove is that the slurm attestor ever *matches* a workload:
# that needs a real Slurm job, and belongs to the consumer's own CI. Here the
# question is only whether the action can enable it.

# shellcheck source=../../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib.sh"

scenario_begin

export SPIRE_DEV_MODE=host
export SPIRE_DEV_TRUST_DOMAIN=attestors.test
export SPIRE_DEV_CONTROLLER_MANAGER=false
export SPIRE_DEV_WORKLOAD_ATTESTORS="slurm"
export SPIRE_DEV_AGENT_EXTRA_PLUGINS='WorkloadAttestor "docker" {
    plugin_data {}
}'
export SPIRE_DEV_ENTRIES="
- spiffeID: myapp
  selectors:
    - systemd:id:spire-dev-attestors-myapp.service
"

spire_dev deploy

AGENT_SOCK="/run/spire/agent/sockets/main/public/api.sock"
AGENT_CONF="/etc/spire/agent/main.conf"

echo
echo "== the agent is up with the extra attestors configured"
# A healthy agent is the load-bearing check: an unknown plugin name is fatal at
# startup, so reaching healthy means the stanza parsed and the plugin resolved.
check "the agent passes its healthcheck" \
  sudo spire-agent healthcheck -socketPath "${AGENT_SOCK}"

INSTALLED="$(sudo cat "${AGENT_CONF}")"
check_contains "the slurm attestor is in the installed config" \
  "${INSTALLED}" 'WorkloadAttestor "slurm"'
check_contains "the raw extra plugin is in the installed config" \
  "${INSTALLED}" 'WorkloadAttestor "docker"'
check_absent "no marker survived into the installed config" \
  "${INSTALLED}" '@@'

echo
echo "== the defaults were added to, not replaced"
# An extra attestor that displaced the built-ins would break every existing
# consumer, and would do it silently -- the agent still starts.
check_contains "the systemd attestor is still configured" \
  "${INSTALLED}" 'WorkloadAttestor "systemd"'
check_contains "the unix attestor is still configured" \
  "${INSTALLED}" 'WorkloadAttestor "unix"'

echo
echo "== a systemd workload still gets its SVID"
# The end-to-end version of the check above: the default attestation path has to
# keep working with the extra plugins loaded.
ID="$(fetch_workload_svid_id spire-dev-attestors-myapp "${AGENT_SOCK}")"
check_equals "the workload gets the SPIFFE ID it was registered for" \
  "spiffe://attestors.test/myapp" "${ID}"

echo
echo "== nothing failed to load"
# Deliberately a negative check on a specific error rather than a positive check
# for the plugin name: the agent's "loaded" log line format is not a contract, and
# an assertion on it would go red for a cosmetic change. The healthcheck above is
# the positive proof, since an unrecognised plugin name is fatal at startup.
# check_absent fails on an empty haystack, so an unreadable journal is caught too.
JOURNAL="$(sudo journalctl -u "spire-agent@main" --no-pager 2>/dev/null || true)"
check_absent "no plugin was rejected as unknown" \
  "${JOURNAL}" "no such builtin plugin"

scenario_end
