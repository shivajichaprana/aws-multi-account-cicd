# Contributing

Thanks for your interest in improving this project. Contributions of all sizes
are welcome — bug reports, documentation fixes, and new pipeline patterns.

## Ground rules

- Keep changes scoped. One logical change per pull request.
- All Terraform must pass `terraform fmt -check` and `terraform validate`.
- All YAML and shell must pass `yamllint` and `shellcheck` (see below).
- Follow [Conventional Commits](https://www.conventionalcommits.org/) for commit
  messages (`feat:`, `fix:`, `docs:`, `ci:`, `refactor:`, `test:`, `chore:`).
- Do not commit real account ids, ARNs, state files, or `*.tfvars`. Use the
  documented AWS placeholder account ids (`123456789012`, `111111111111`,
  `222222222222`) in examples. `.gitignore` already excludes state, tfvars, and
  generated scan reports — keep it that way.

## Local checks before opening a PR

The [`Makefile`](Makefile) wraps exactly what CI runs. The one-liner:

```bash
make check        # fmt-check + validate + lint (yaml + shell)
```

Individual targets:

```bash
make fmt          # rewrite Terraform to canonical format
make fmt-check    # fail on formatting drift (what CI runs)
make validate     # backend-less init + validate, both root modules
make lint         # yamllint + shellcheck
make help         # list all targets
```

Tooling the linters expect on PATH: `terraform` (>= 1.6), `yamllint`, and
`shellcheck`. Lint configuration lives in [`.yamllint.yml`](.yamllint.yml) and
[`.shellcheckrc`](.shellcheckrc); both document any non-default rules.

## What CI enforces

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push and
pull request to `main`:

- **terraform** — `fmt -check`, backend-less `init`, and `validate` for both the
  `tooling-account` and `target-account` root modules (matrix).
- **lint** — `yamllint` of the buildspecs/appspec/workflows, a YAML parse
  smoke-test, and `shellcheck` of every operator and pipeline script.

CI is read-only and needs no AWS credentials, so it runs on fork PRs too.

## Adding a new pipeline stage or environment

The promotion path is data-driven via the `deployment_stages` variable; see
[docs/onboarding-new-service.md](docs/onboarding-new-service.md) for how to add
an environment or approval gate without changing pipeline code.

## Questions and discussion

Open a Discussion in the repository or comment on the relevant pull request.

## Reporting a vulnerability

Please do not open a public issue for security problems. Instead, open a private
report at:
https://github.com/shivajichaprana/aws-multi-account-cicd/security/advisories/new
