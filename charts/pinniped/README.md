# pinniped

Helm chart for [Pinniped](https://pinniped.dev) Supervisor and Concierge,
derived from the official upstream install manifests for v0.47.0:

- `https://get.pinniped.dev/v0.47.0/install-pinniped-supervisor.yaml`
- `https://get.pinniped.dev/v0.47.0/install-pinniped-concierge.yaml`

The rendered resources match upstream, with these deliberate deviations:

- The namespace is freely configurable (upstream hardcodes
  `pinniped-supervisor` / `pinniped-concierge`).
- A `pinniped-supervisor` Service exposing the issuer endpoint (port 8443)
  and an optional Ingress are added — upstream leaves exposure to the user.
- `kapp.k14s.io/*` annotations are dropped (kapp-specific).
- Standard Helm labels are added next to the upstream `app` labels.
- The `stackitSKE.enabled` flag adjusts RBAC for STACKIT SKE (see below).

Resource names are kept identical to upstream because the static
`pinniped.yaml` configs reference them — therefore **only one release of
this chart can be installed per cluster** (cluster-scoped resources like
APIServices and ClusterRoles are singletons anyway).

## Installing

```console
helm install pinniped ./charts/pinniped \
  --namespace pinniped --create-namespace
```

Both components install into the release namespace by default. Use
`namespace`, `supervisor.namespaceOverride` or `concierge.namespaceOverride`
to change that; set `createNamespaces=true` if the chart should create the
Namespace objects itself.

## STACKIT SKE

SKE (Gardener-based) ships a platform-managed `ValidatingAdmissionPolicy`
that rejects any RBAC binding to the group `system:authenticated`:

```
Binding permissions to group system:authenticated is disallowed for security reasons
```

The upstream concierge manifest binds exactly that group in the
`pinniped-concierge-pre-authn-apis` ClusterRoleBinding, so the install fails
on SKE. Set:

```yaml
stackitSKE:
  enabled: true
```

to bind only `system:unauthenticated` — the anonymous path used by the
pinniped CLI during login. The only functional loss is `pinniped whoami`
through the aggregation layer for already-authenticated users; on SKE the
client traffic goes through the concierge's impersonation proxy anyway
(anonymous auth is disabled on the Gardener kube-apiserver, and the
CredentialIssuer's `impersonationProxy.mode: auto` detects the managed
control plane). See [PROBLEM.md](../../PROBLEM.md) for the full analysis.

## Identity providers and external secrets

Identity providers, FederationDomains, OIDCClients and Concierge
authenticators are passed through verbatim — every field of the upstream
API is available under `spec`. Client credentials are referenced by Secret
name, so they can come from an external source (External Secrets Operator,
SOPS, sealed-secrets, ...):

```yaml
supervisor:
  federationDomains:
    - name: demo
      spec:
        issuer: https://login.example.com/demo-issuer

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
          # external Secret of type secrets.pinniped.dev/oidc-client
          # with keys clientID and clientSecret
          secretName: keycloak-oidc-client

concierge:
  jwtAuthenticators:
    - name: supervisor
      spec:
        issuer: https://login.example.com/demo-issuer
        audience: my-cluster-audience
```

The referenced Secret must live in the supervisor namespace and look like:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-oidc-client
  namespace: pinniped
type: secrets.pinniped.dev/oidc-client
stringData:
  clientID: pinniped
  clientSecret: "..."
```

Alternatively the chart can create such Secrets from values via
`supervisor.secrets` (not recommended for real credentials).

## Values

See [values.yaml](values.yaml) for the full documented list. Highlights:

| Key | Default | Description |
|---|---|---|
| `namespace` | `""` (release namespace) | Namespace for both components |
| `createNamespaces` | `false` | Create Namespace objects |
| `stackitSKE.enabled` | `false` | SKE-compatible RBAC (see above) |
| `image.repository` / `image.tag` / `image.digest` | upstream v0.47.0 | Pinniped server image |
| `supervisor.enabled` / `concierge.enabled` | `true` | Toggle components |
| `supervisor.podLabels` / `concierge.podLabels` | `{}` | Extra pod labels |
| `supervisor.config` / `concierge.config` | `{}` | Deep-merged into pinniped.yaml |
| `supervisor.service.*` | ClusterIP 443 | Issuer endpoint Service |
| `supervisor.ingress.*` | disabled | Issuer endpoint Ingress |
| `supervisor.federationDomains` | `[]` | FederationDomain CRs |
| `supervisor.identityProviders` | `[]` | OIDC/LDAP/AD/GitHub IDP CRs |
| `supervisor.oidcClients` | `[]` | OIDCClient CRs |
| `supervisor.secrets` | `[]` | Chart-managed credential Secrets |
| `concierge.credentialIssuer.spec` | impersonation proxy `auto` | CredentialIssuer spec |
| `concierge.jwtAuthenticators` | `[]` | JWTAuthenticator CRs |
| `concierge.webhookAuthenticators` | `[]` | WebhookAuthenticator CRs |

## Upgrading Pinniped

The CRDs in `crds/` and the pinned image digest belong to v0.47.0. To move
to a newer Pinniped version, regenerate both from the new upstream
manifests — Helm does not upgrade CRDs automatically.
