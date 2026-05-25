# Contributing

Thanks for your interest in improving this project. Contributions of all sizes
are welcome — bug reports, documentation fixes, and new pipeline patterns.

## Ground rules

- Keep changes scoped. One logical change per pull request.
- All Terraform must pass `terraform fmt -check` and `terraform validate`.
- Follow [Conventional Commits](https://www.conventionalcommits.org/) for commit
  messages (`feat:`, `fix:`, `docs:`, `ci:`, `refactor:`, `test:`, `chore:`).
- Do not commit real account ids, ARNs, state files, or `*.tfvars`. Use the
  documented AWS placeholder account id `123456789012` in examples.

## Local checks before opening a PR

```bash
terraform -chdir=terraform/tooling-account fmt -check
terraform -chdir=terraform/tooling-account validate
terraform -chdir=terraform/target-account  fmt -check
terraform -chdir=terraform/target-account  validate
```

## Questions and discussion

Open a Discussion in the repository or comment on the relevant pull request.

## Reporting a vulnerability

Please do not open a public issue for security problems. Instead, open a private
report at:
https://github.com/shivajichaprana/aws-multi-account-cicd/security/advisories/new
