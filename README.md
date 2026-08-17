# spire-dev-action

[![Apache 2.0 License](https://img.shields.io/github/license/spiffe/spire-dev-action)](https://opensource.org/licenses/Apache-2.0)
[![Development Phase](https://github.com/spiffe/spiffe/blob/main/.img/maturity/dev.svg)](https://github.com/spiffe/spiffe/blob/main/MATURITY.md#development)

A GitHub Action that stands up a working [SPIRE](https://spiffe.io/) deployment so a
workflow can test an application against real SPIFFE identities.

It supports two deployment architectures, so the test environment can match how the
application actually runs:

| `mode` | What it deploys | For |
|---|---|---|
| `host` | SPIRE server, agent and optional components from the [spire-examples](https://github.com/spiffe/spire-examples) deb packages, under systemd on the runner | a raw unix application |
| `k8s` | The [helm-charts-hardened](https://github.com/spiffe/helm-charts-hardened) charts, into an existing cluster or a kind cluster it creates | a containerized Kubernetes application |

The deployment is left running for the steps that follow, and the action exports
`SPIFFE_ENDPOINT_SOCKET`, so an application built on any SPIFFE library usually needs
no configuration at all.

## Quick start

### A raw unix application

```yaml
- uses: spiffe/spire-dev-action@v1
  with:
    mode: host
    trust-domain: example.org
    entries: |
      - spiffeID: myapp
        selectors:
          - systemd:id:myapp.service

# SPIFFE_ENDPOINT_SOCKET is already set, so this needs no SPIRE-specific config.
- run: systemd-run --wait --pipe --unit=myapp ./my-application --test
```

The unit name has to match the `systemd:id:` selector — that is how SPIRE identifies
the process. See [Identifying a unix workload](#identifying-a-unix-workload).

### A containerized application

```yaml
- uses: spiffe/spire-dev-action@v1
  id: spire
  with:
    mode: k8s
    cluster: kind
    trust-domain: example.org
    entries: |
      - spiffeID: myapp
        parentID: spiffe://example.org/spire/server
        selectors:
          - k8s:ns:default
          - k8s:pod-label:app:myapp

- run: kubectl apply -f my-application.yaml
```

The application's pod gets the workload API socket from the CSI driver:

```yaml
volumes:
  - name: spiffe-workload-api
    csi:
      driver: csi.spiffe.io   # ${{ steps.spire.outputs.csi-driver-name }}
      readOnly: true
```

### Collecting diagnostics when something fails

```yaml
- uses: spiffe/spire-dev-action/diagnostics@v1
  if: always()
  with:
    mode: host
```

This writes unit status, logs, registration entries and the generated configuration
to the run summary, and uploads them as an artifact. Worth adding from the start:
when SPIRE does not come up, this is what says why.

## Registration entries

Nothing gets an identity without a registration entry. There are two ways to declare
them, and they can be combined.

### The `entries` input

A YAML list. `spiffeID` and `selectors` are required; everything else is optional.

```yaml
entries: |
  - spiffeID: myapp                       # a path, so the trust domain is prepended
    selectors: [systemd:id:myapp.service]

  - name: worker                          # optional; derived from spiffeID otherwise
    spiffeID: /workers/batch              # a leading slash is fine too
    parentID: spiffe://example.org/agent/node1   # optional; see below
    selectors:
      - systemd:id:worker.service
      - unix:uid:1000
    dnsNames: [worker.example.org]
    federatesWith: [other.org]
    admin: false
    downstream: false
    storeSVID: false                      # host mode only, see the note below
    x509SVIDTTL: 3600                     # seconds
    jwtSVIDTTL: 300
    hint: primary
```

A `spiffeID` without a `spiffe://` scheme is treated as a path under the trust
domain, so entries stay portable if the trust domain changes. `parentID` works the
same way, and defaults to the agent (`spiffe://<trust-domain>/agent/<node-id>`) in
host mode and the server (`spiffe://<trust-domain>/spire/server`) in k8s mode.

Selectors are `type:value` strings, split on the first colon only — so
`unix:path:/usr/bin/app` parses as type `unix`, value `path:/usr/bin/app`. The
`{type: ..., value: ...}` object form is also accepted.

`entries-file` takes the same list from a file, and may be used together with
`entries`.

### The `manifests-dir` input

For entries expressed as `ClusterStaticEntry` (and, in k8s mode, `ClusterSPIFFEID`)
manifests. This requires `spire-controller-manager`, and supplying it turns the
controller-manager on when `controller-manager` is left at `auto`.

```yaml
- uses: spiffe/spire-dev-action@v1
  with:
    mode: host
    manifests-dir: test/spire-manifests
```

Manifests may reference `${SPIFFE_TRUST_DOMAIN}`, which the controller-manager
expands, so the same manifest works against any trust domain:

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterStaticEntry
metadata:
  name: myapp
spec:
  parentID: spiffe://${SPIFFE_TRUST_DOMAIN}/agent/node1
  spiffeID: spiffe://${SPIFFE_TRUST_DOMAIN}/myapp
  selectors:
    - systemd:id:myapp.service
```

### With or without the controller-manager

Both inputs above describe entries the same way; `controller-manager` decides how they
are created.

- **`controller-manager: false`** — entries are created with the `spire-server` CLI.
  Nothing else runs, which is the smaller and simpler deployment. `manifests-dir`
  cannot be used.
- **`controller-manager: true`** — `spire-controller-manager` runs in static manifest
  mode and reconciles entries from a directory. Needed for `manifests-dir`, and in k8s
  mode it is also what creates the chart's own `ClusterSPIFFEID`s.
- **`controller-manager: auto`** (default) — in host mode, on only if `manifests-dir`
  is set; in k8s mode, always on, matching the chart default.

One field differs between the two: `storeSVID` is supported by the CRD and by the
CLI, but not by the helm chart's `clusterStaticEntries` values, so using it in k8s
mode is rejected with an explicit error rather than silently ignored.

## Identifying a unix workload

In host mode SPIRE identifies a process by attesting it, and the most useful attestor
is `systemd`, whose selector is the unit the process runs under. Running the
application as a transient unit is therefore how it gets a scoped identity, with no
container involved:

```yaml
- uses: spiffe/spire-dev-action@v1
  with:
    mode: host
    entries: |
      - spiffeID: myapp
        selectors: [systemd:id:myapp.service]

- run: systemd-run --wait --pipe --unit=myapp ./my-application
```

The `unix` workload attestor is also enabled, so `unix:uid:`, `unix:gid:` and
`unix:path:` selectors work for a process not under its own unit.

To check by hand what a given unit would be issued:

```bash
sudo systemd-run --wait --pipe --unit=myapp spire-agent api fetch jwt -audience test
```

## Optional components

| Input | Default | What it adds |
|---|---|---|
| `oidc-discovery-provider` | `true` in k8s, `false` in host | Serves the JWKS and OIDC discovery document, for verifying JWT-SVIDs outside SPIRE. In k8s mode the chart's own `helm test` uses it as a workload check, which is why it is on by default there. |
| `identity-exchange` | `false` | [spire-identity-exchange](https://github.com/spiffe/spire-identity-exchange), which exchanges an external credential such as a GitHub Actions OIDC token for an SVID. |

`identity-exchange` deploys with every auth plugin disabled in host mode, and with a
narrowly scoped `k8s_psat` plugin in k8s mode. Which credentials to accept is policy
specific to the caller's test, so grant it deliberately: supply
`identity-exchange-config` in host mode, or override
`spire-identity-exchange.auth.plugins` through `values` in k8s mode.

## k8s mode notes

- **`cluster: existing`** (default) uses the current kubectl context. **`cluster: kind`**
  creates a cluster; `k8s-version` selects the Kubernetes version.
- Everything is installed into one namespace (`namespace`, default `spire-server`),
  which is labelled `pod-security.kubernetes.io/enforce=privileged` because the agent
  and CSI driver mount host paths.
- `values` is applied last and overrides everything the action sets. One path per
  line, or inline YAML.
- The CSI driver is a cluster-scoped object with a fixed name, so two SPIRE
  installations in one cluster will conflict.

## Cleaning up

Teardown is opt-in and never automatic — the deployment exists so that later steps can
use it. A disposable runner needs no teardown at all; this is for a reused
self-hosted one.

```yaml
- uses: spiffe/spire-dev-action/teardown@v1
  if: always()
  with:
    mode: host
```

In k8s mode with `cluster: kind` this deletes the cluster; otherwise it uninstalls the
releases and the cluster-scoped objects `helm uninstall` leaves behind. In host mode it
stops the units and removes the generated configuration and state, leaving the packages
installed.

## Inputs and outputs

Every input is listed with its default and meaning in [action.yml](action.yml). The
notable outputs:

| Output | Mode | Use |
|---|---|---|
| `agent-socket-path` | host | The workload API socket. Also exported as `SPIFFE_ENDPOINT_SOCKET`. |
| `server-socket-path` | host | For `spire-server` CLI calls. |
| `csi-driver-name` | k8s | Put in a pod spec to mount the workload API. |
| `server-pod` | k8s | For `spire-server` CLI calls via `kubectl exec`. |
| `bundle-file` | both | The trust bundle in PEM form, for verifying SVIDs out of band. |
| `oidc-discovery-url` | both | Base URL of the discovery provider, when enabled. |

## What this is not

This deploys SPIRE the way a test needs it, not the way production does. It uses
`insecure_bootstrap` and join-token node attestation on a host, plain HTTP for the
discovery provider, a self-signed certificate for the identity exchange, an unpinned
credential composer plugin, and an sqlite datastore. All of that is fine on a
disposable runner and wrong everywhere else.

Host mode in particular installs packages, writes under `/etc` and starts services on
the machine it runs on. It refuses to do so unless it detects CI or
`allow-host-modification: true` is set.

## Versions

Package, chart and node image versions are pinned in [versions.json](versions.json).
Override the whole file with `versions-file`, or any single value by setting the
corresponding `SPIRE_DEV_*` environment variable.

## Running outside GitHub Actions

The action is a thin wrapper: all the logic is in `scripts/`, which is plain bash with
no dependency on GitHub Actions. Every input arrives as a `SPIRE_DEV_*` environment
variable, and `scripts/lib/log.sh` is the only file that knows about the CI system.

```bash
SPIRE_DEV_MODE=host \
SPIRE_DEV_TRUST_DOMAIN=example.org \
SPIRE_DEV_ALLOW_HOST_MODIFICATION=true \
scripts/spire-dev.sh deploy
```

`scripts/spire-dev.sh` with no arguments lists the variables. This is what makes a
GitLab equivalent a matter of replacing `log.sh`; that port has not been done yet.

## Development

```bash
tests/entries/run-tests.sh
```

```bash
tests/k8s-values/run-tests.sh
```

Both run anywhere: they are pure rendering checks, needing no cluster and no root.
`tests/entries` diffs the three entry representations against golden files (regenerate
with `--update`), and `tests/k8s-values` renders the composed values against the real
chart, which is what catches the values this action generates drifting from what the
chart accepts.

The scenarios under `tests/scenarios/` deploy real SPIRE and **modify the machine they
run on**. They are for a disposable CI runner and refuse to run otherwise; the
`test.yaml` workflow discovers and runs them.
