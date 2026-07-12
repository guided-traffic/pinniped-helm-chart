# pinniped-helm-chart

Unofficial Helm chart for [Pinniped](https://pinniped.dev) — Supervisor and
Concierge — derived from the official upstream install manifests for
**v0.47.0**. The Pinniped project itself does not publish a Helm chart.

The chart lives in [charts/pinniped](charts/pinniped/); see its
[README](charts/pinniped/README.md) for the full configuration reference.

## Features

- Supervisor and Concierge in one chart, individually toggleable
  (`supervisor.enabled` / `concierge.enabled`)
- Freely configurable namespace — upstream hardcodes `pinniped-supervisor` /
  `pinniped-concierge`; here `namespace` plus per-component
  `namespaceOverride` decide where everything lands
- Additional pod labels and annotations per deployment
  (`supervisor.podLabels`, `concierge.podLabels`, ...)
- Detailed Pinniped configuration through verbatim pass-through specs:
  FederationDomains, identity providers (OIDC, LDAP, Active Directory,
  GitHub), OIDCClients, JWT/Webhook authenticators, CredentialIssuer, plus
  deep-merge overrides for both `pinniped.yaml` static configs
- IDP `client-id`/`client-secret` come from a referenced Secret, so they can
  be provided externally (External Secrets Operator, sealed-secrets, SOPS,
  ...) — no credentials in values required
- `stackitSKE.enabled` flag for STACKIT SKE clusters (see below)
- Service (and optional Ingress) for the Supervisor issuer endpoint, which
  the upstream manifests leave entirely to the user

## Quick start

The chart is served as a Helm repository via GitHub Pages:

```console
helm repo add pinniped-helm-chart https://guided-traffic.github.io/pinniped-helm-chart
helm repo update
helm install pinniped pinniped-helm-chart/pinniped \
  --namespace pinniped --create-namespace
```

On STACKIT SKE additionally set `--set stackitSKE.enabled=true`.

Alternatively, install straight from a checkout:

```console
helm install pinniped ./charts/pinniped \
  --namespace pinniped --create-namespace
```

Minimal login wiring (values file):

```yaml
supervisor:
  federationDomains:
    - name: demo
      spec:
        issuer: https://login.example.com/demo

  identityProviders:
    - kind: OIDCIdentityProvider
      name: keycloak
      spec:
        issuer: https://keycloak.example.com/realms/main
        authorizationConfig:
          additionalScopes: [offline_access, groups, email]
        claims:
          username: email
          groups: groups
        client:
          # externally provided Secret of type secrets.pinniped.dev/oidc-client
          # with keys clientID and clientSecret, in the supervisor namespace
          secretName: keycloak-oidc-client

concierge:
  jwtAuthenticators:
    - name: supervisor
      spec:
        issuer: https://login.example.com/demo
        audience: my-cluster-audience
```

## STACKIT SKE: the system:authenticated problem

STACKIT SKE (Gardener-based) installs a cluster-wide, platform-managed
`ValidatingAdmissionPolicy` that cannot be edited or removed. Its CEL rule
rejects every ClusterRoleBinding/RoleBinding containing a subject of
`kind: Group, name: system:authenticated`:

```
ValidatingAdmissionPolicy 'ske.stackit.cloud.idp-access-policy.block' ... denied request:
Binding permissions to group system:authenticated is disallowed for security reasons
```

Background: with SKE SSO, every user of the STACKIT organization ends up in
`system:authenticated` — a binding to that group would accidentally grant
rights to the whole organization. Only this exact group is blocked;
`system:unauthenticated`, ServiceAccounts, users and other groups are fine.

The upstream Concierge manifest contains exactly such a binding: the
`pinniped-concierge-pre-authn-apis` ClusterRoleBinding grants
`system:authenticated` **and** `system:unauthenticated` access to the
aggregated pre-auth APIs (`TokenCredentialRequest`, `WhoAmIRequest`). On SKE
the whole install therefore fails at admission.

With `stackitSKE.enabled=true` the chart deviates from upstream and binds
only `system:unauthenticated`. That is sufficient because:

1. **The critical path is the anonymous one.** During login the pinniped CLI
   has no cluster identity yet (that is what it is trying to obtain), so the
   `TokenCredentialRequest` arrives as `system:anonymous` in group
   `system:unauthenticated`. The `system:authenticated` subject mainly
   served `pinniped whoami` / re-login for already-authenticated users.
   A ServiceAccount binding would *not* work instead: it would only ever
   authorize in-cluster pods, never the external login flow.
2. **On SKE the login flow uses the impersonation proxy anyway.** Gardener
   disables anonymous auth on the kube-apiserver (unauthenticated requests
   get 401), so the aggregation layer is unreachable for the login call
   regardless of RBAC. Pinniped detects the managed control plane
   (CredentialIssuer `impersonationProxy.mode: auto`) and serves logins
   through its own impersonation proxy behind a LoadBalancer Service — the
   blocked binding is irrelevant for that path.

Consequences and notes:

- Only loss: `pinniped whoami` via the aggregation layer for
  already-authenticated users; over the impersonation proxy this is
  practically irrelevant.
- Generate kubeconfigs with `pinniped get kubeconfig` — it automatically
  points clients at the impersonation-proxy endpoint instead of the
  kube-apiserver.
- A CredentialIssuer status of
  `KubeClusterSigningCertificate: CouldNotFetchKey` is expected on managed
  clusters (no access to the kube-controller-manager) and not an error;
  `ImpersonationProxy: Success (Listening)` is what matters.
- The chart renders the kube-system/kube-public RoleBindings
  (`extension-apiserver-authentication-reader`, cluster-info reader) with
  explicit namespaces while their subjects point at the ServiceAccounts in
  the configured Pinniped namespace — GitOps tools that rewrite target
  namespaces (e.g. Flux `targetNamespace`) cannot accidentally relocate
  them, which would crashloop both components.

## Versioning

The chart tracks Pinniped v0.47.0: the image is digest-pinned in
`values.yaml` and the CRDs are vendored under `charts/pinniped/crds/`. To
upgrade Pinniped, regenerate both from the new upstream manifests — Helm
does not upgrade CRDs on `helm upgrade`.

## CI and releasing

All workflows run on the self-hosted runner.

**[Test workflow](.github/workflows/ci.yml)** — on every pull request and
on pushes to `main`:

- `helm lint` plus template renders asserting the `stackitSKE` flag
  semantics and the namespace override
- an end-to-end test on a [Kind](https://kind.sigs.k8s.io/) cluster:
  installs the chart, waits for all three aggregated APIServices to become
  `Available`, expects the `KubeClusterSigningCertificate` strategy to
  succeed (control plane is visible on Kind), answers a real
  `WhoAmIRequest` through the aggregation layer, then upgrades with
  `stackitSKE.enabled=true` and verifies the ClusterRoleBinding subjects
  on the cluster

**Semantic release** — after a successful test run on `main`,
[semantic-release](https://semantic-release.gitbook.io/) analyzes the
[Conventional Commits](https://www.conventionalcommits.org/) since the last
release, writes `CHANGELOG.md`, bumps the `version` in
`charts/pinniped/Chart.yaml`, commits, and pushes a `vX.Y.Z` git tag.
Use `feat:`/`fix:`/`feat!:` commit prefixes to control the version bump;
other types (`chore:`, `docs:`, ...) do not release.

**[Release Charts workflow](.github/workflows/release.yml)** — runs only
on `v*` tags: verifies the tag matches the chart version, packages the
chart with [chart-releaser](https://github.com/helm/chart-releaser-action),
attaches the `.tgz` to the GitHub Release for that tag and updates
`index.yaml` on the `gh-pages` branch, which GitHub Pages serves at
`https://guided-traffic.github.io/pinniped-helm-chart`.

One-time repository setup:

1. Create an empty `gh-pages` branch:

   ```console
   git switch --orphan gh-pages
   git commit --allow-empty -m "Init gh-pages"
   git push origin gh-pages
   git switch main
   ```

2. In the repository settings, enable **Pages** with source
   **Deploy from a branch**, branch `gh-pages`, folder `/ (root)`.

3. Provide the secrets `BOT_PAT` (PAT with `contents: write`;
   semantic-release pushes the release commit and tag with it — a plain
   `GITHUB_TOKEN` push would not trigger the tag-based release workflow)
   and `DOCKERHUB_PAT` (Docker Hub pulls for the Kind node image).

## License

[Apache-2.0](LICENSE)
