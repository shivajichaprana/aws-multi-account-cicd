# aws-multi-account-cicd

Multi-account CI/CD on AWS: a centrally-managed AWS CodePipeline that lives in a
dedicated **tooling account** and deploys into separate **dev / staging / prod
target accounts** by assuming least-privilege, permission-boundary-bounded
deployer roles. Deployments to ECS use CodeDeploy blue/green with a linear
canary strategy and CloudWatch-alarm-driven automatic rollback.

This repository is infrastructure-as-code (Terraform) plus the pipeline
definitions (buildspecs / appspec) and operator scripts that wire it together.

## Why a separate tooling account?

Concentrating the pipeline, artifact store, and signing material in one tooling
account keeps the blast radius of the CI/CD system away from the workloads it
deploys. Target accounts trust the tooling account's pipeline role to assume a
single, tightly-scoped deployer role — nothing in a target account holds
standing credentials for the pipeline, and the pipeline never holds standing
credentials in a target account.

```
                         +--------------------------+
                         |     Tooling Account      |
                         |                          |
   git push  ----------> |  CodePipeline            |
                         |    |                     |
                         |    +-- CodeBuild (build,  |
                         |    |     test, package)   |
                         |    +-- S3 artifacts + KMS |
                         |    +-- pipeline role      |
                         +----------|---------------+
                                    | sts:AssumeRole (per stage)
            +-----------------------+-----------------------+
            v                       v                       v
   +-----------------+    +-----------------+    +-----------------+
   |   dev account   |    | staging account |    |   prod account  |
   | deployer role   |    | deployer role   |    | deployer role   |
   | (perm boundary) |    | (perm boundary) |    | (perm boundary) |
   | CodeDeploy B/G  |    | CodeDeploy B/G  |    | CodeDeploy B/G  |
   +-----------------+    +-----------------+    +-----------------+
```

## Repository layout

| Path | Purpose |
|------|---------|
| `terraform/tooling-account/` | Root module applied in the tooling account: pipeline role, CodePipeline, CodeBuild, artifact bucket + KMS. |
| `terraform/target-account/`  | Root module applied in **each** target account: deployer role, permission boundary, CodeDeploy, deployment alarms. |
| `pipelines/`                 | `buildspec-*.yml` and `appspec.yml` consumed by CodeBuild / CodeDeploy. |
| `scripts/`                   | Operator helper scripts (canary validation, rollback drills). |
| `docs/`                      | Architecture notes, onboarding, and runbooks. |
| `.github/workflows/`         | Repository CI (fmt / validate / lint / scan). |

## Prerequisites

- Terraform >= 1.6
- AWS provider >= 5.40
- An AWS Organizations setup with at least a tooling account and one target account
- Credentials for each account (the two root modules are applied with different
  account credentials / provider profiles)

## Bootstrapping order

1. **Target accounts first.** Apply `terraform/target-account/` in each of
   dev, staging, and prod. This creates the deployer role and its permission
   boundary, trusting the tooling account's pipeline role ARN. Because the
   pipeline role does not exist yet on the very first apply, the trust policy is
   expressed against the role *ARN by name* (a principal ARN does not require
   the role to exist at policy-creation time).
2. **Tooling account next.** Apply `terraform/tooling-account/`. This creates
   the pipeline role with `sts:AssumeRole` permission scoped to exactly the
   deployer role ARNs in the target accounts, plus the pipeline itself.

```bash
git clone https://github.com/shivajichaprana/aws-multi-account-cicd.git
cd aws-multi-account-cicd

# In each target account (dev/staging/prod):
cd terraform/target-account
cp terraform.tfvars.example terraform.tfvars   # fill in real account ids
terraform init && terraform apply

# Then, in the tooling account:
cd ../tooling-account
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply
```

> Never commit a real `terraform.tfvars`; only the `*.example` files are tracked.
> Account ids in the examples are AWS documentation placeholders, not real
> accounts.

## Security model in one line

The pipeline role can assume **only** the named deployer roles; each deployer
role can do **only** what its permission boundary allows, regardless of the
policies later attached to it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues should be reported
through a private GitHub Security Advisory rather than a public issue:
https://github.com/shivajichaprana/aws-multi-account-cicd/security/advisories/new

## License

[MIT](LICENSE).
