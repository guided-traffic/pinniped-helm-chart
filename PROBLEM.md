# Pinniped auf STACKIT SKE: das `system:authenticated`-Problem

## Symptom

Die Flux-Kustomization `pinniped-concierge` schlug beim Server-Side-Apply (Dry-Run) fehl:

```
ClusterRoleBinding/pinniped-concierge-pre-authn-apis dry-run failed (Forbidden):
ValidatingAdmissionPolicy 'ske.stackit.cloud.idp-access-policy.block' with binding
'ske.stackit.cloud.idp-access-policy.block' denied request: Binding permissions to
group system:authenticated is disallowed for security reasons
```

Dadurch wurde das gesamte Concierge-Manifest nicht angewendet (Flux wendet atomar an),
und der Concierge kam nie auf den Cluster.

## Ursachenanalyse

### Was die SKE-Policy tatsächlich verbietet

STACKIT SKE (Gardener-basiert) installiert eine cluster-weite, plattform-verwaltete
`ValidatingAdmissionPolicy`, die nicht editierbar ist
(`resources.gardener.cloud/managed-by: gardener`). Die entscheidende CEL-Validierung:

```yaml
validations:
  - expression: object.subjects.filter(s, s.kind == "Group" && s.name == "system:authenticated").size() == 0
    message: Binding permissions to group system:authenticated is disallowed for security reasons
```

Wichtige Erkenntnis: Die Policy verbietet **ausschließlich** Subjects mit
`kind: Group, name: system:authenticated` in ClusterRoleBindings/RoleBindings.
**Nicht** verboten sind:

- `system:unauthenticated` (Gruppe der anonymen Requests)
- ServiceAccounts, Users, beliebige andere Gruppen

Hintergrund der Policy: Bei SKE landen alle Nutzer der STACKIT-Organisation über das
SKE-SSO in `system:authenticated` — ein Binding darauf würde versehentlich der ganzen
Organisation Rechte geben.

### Was das Upstream-Binding macht

Das Pinniped-Upstream-Manifest enthält:

```yaml
kind: ClusterRoleBinding
metadata:
  name: pinniped-concierge-pre-authn-apis
subjects:
- kind: Group
  name: system:authenticated    # <- von SKE-Policy blockiert
- kind: Group
  name: system:unauthenticated  # <- erlaubt
roleRef:
  kind: ClusterRole
  name: pinniped-concierge-pre-authn-apis  # create/list auf TokenCredentialRequest + WhoAmIRequest
```

Zweck: Clients dürfen die aggregierten APIs `TokenCredentialRequest`
(OIDC-Token gegen Cluster-Zertifikat tauschen) und `WhoAmIRequest` aufrufen.

### Warum ein ServiceAccount-Binding NICHT funktioniert

Naheliegende Idee: statt der Gruppe einen ServiceAccount binden. Geht nicht, weil der
Aufrufer des `TokenCredentialRequest` der **externe Nutzer mit der pinniped-CLI** ist —
zum Zeitpunkt des Aufrufs hat er noch **keine Cluster-Identität** (genau die will er ja
erst bekommen). Der Request kommt anonym an, der Aufrufer ist also `system:anonymous`
in der Gruppe `system:unauthenticated`. Ein ServiceAccount-Subject würde nur Pods
innerhalb des Clusters berechtigen, nie den Login-Flow von außen.

### Warum `system:authenticated` hier verzichtbar ist

Zwei Gründe:

1. **Der kritische Pfad ist der anonyme.** Der Login-Flow braucht nur
   `system:unauthenticated`. `system:authenticated` diente primär dazu, dass bereits
   authentifizierte Nutzer `pinniped whoami` bzw. Re-Login aufrufen können — verzichtbar.

2. **Auf SKE läuft der Flow ohnehin über den Impersonation Proxy.** Verifiziert:
   `curl -k https://api.artifact-p.…/version` ohne Credentials liefert **401** —
   anonymous-auth am kube-apiserver ist deaktiviert (Gardener-Default). Damit kann der
   `TokenCredentialRequest` den Aggregation-Layer des API-Servers gar nicht anonym
   erreichen, RBAC hin oder her. Pinniped erkennt das selbst (CredentialIssuer
   `spec.impersonationProxy.mode: auto`, keine sichtbaren Control-Plane-Nodes → Managed
   Cluster) und startet den **Impersonation Proxy** hinter einem eigenen
   LoadBalancer-Service. Die CLI spricht dann diesen Proxy an, der die
   Authentifizierung selbst durchführt — das kube-apiserver-RBAC-Binding ist für den
   Login-Pfad nicht mehr relevant.

## Lösung

Kustomize-Patch im Overlay [apps/iam/pinniped/concierge/kustomization.yml](apps/iam/pinniped/concierge/kustomization.yml)
(das vendored Upstream-Manifest bleibt unverändert):

```yaml
- target:
    group: rbac.authorization.k8s.io
    version: v1
    kind: ClusterRoleBinding
    name: pinniped-concierge-pre-authn-apis
  patch: |-
    - op: replace
      path: /subjects
      value:
        - kind: Group
          name: system:unauthenticated
          apiGroup: rbac.authorization.k8s.io
```

Ersetzt die Subject-Liste komplett: `system:authenticated` fliegt raus,
`system:unauthenticated` bleibt. Die CEL-Validierung der SKE-Policy ist damit erfüllt,
das Binding wird akzeptiert, der Concierge wird deployt.

## Verifikation

- ClusterRoleBinding `pinniped-concierge-pre-authn-apis` auf dem Cluster angelegt,
  Subjects enthalten nur noch `system:unauthenticated`
- Concierge-Pods `1/1 Running` (namespace `iam`)
- CredentialIssuer-Status:
  - `ImpersonationProxy: Success (Listening)` — LoadBalancer mit externer IP provisioniert
  - `KubeClusterSigningCertificate: Error (CouldNotFetchKey)` — laut Pinniped-Meldung
    selbst erwartetes Verhalten auf Managed-Clustern (kein Zugriff auf
    kube-controller-manager), kein Fehler

## Einschränkungen / Randnotizen

- `pinniped whoami` mit bereits vorhandener Cluster-Identität über den
  Aggregation-Layer funktioniert ohne das `system:authenticated`-Binding nicht.
  Über den Impersonation Proxy ist der Verlust praktisch irrelevant.
- Der Login-Endpunkt für Clients ist der Impersonation-Proxy-LoadBalancer, nicht der
  kube-apiserver — kubeconfigs mit `pinniped get kubeconfig` generieren, das trägt den
  Proxy-Endpunkt automatisch ein.
- Verwandtes, separates Problem (gleiche Fehlersuche): `targetNamespace: iam` in den
  Flux-Kustomizations verschob auch die kube-system/kube-public-RoleBindings nach
  `iam`, wodurch Supervisor und Concierge die ConfigMap
  `kube-system/extension-apiserver-authentication` nicht lesen durften und
  crashloopten. Gelöst durch die separate Kustomization
  [apps/iam/pinniped/cluster-rbac](apps/iam/pinniped/cluster-rbac/rbac.yml) ohne
  `targetNamespace`, die dieses RBAC gezielt in kube-system/kube-public anlegt
  (Subjects zeigen auf die ServiceAccounts in `iam`).
