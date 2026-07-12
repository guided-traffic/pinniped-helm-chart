# pinniped-helm-chart

Unofficial Helm chart for [Pinniped](https://pinniped.dev) (Supervisor +
Concierge), derived from the official v0.47.0 install manifests, with
STACKIT SKE support.

- Chart: [charts/pinniped](charts/pinniped/) — see its
  [README](charts/pinniped/README.md) for configuration and examples
- [PROBLEM.md](PROBLEM.md) — why plain upstream manifests fail on STACKIT
  SKE (`system:authenticated` binding blocked) and how the chart's
  `stackitSKE.enabled` flag solves it
