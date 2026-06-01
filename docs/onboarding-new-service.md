# Onboarding a new service to the pipeline

This guide connects a new application repository to the multi-account pipeline.
It assumes the tooling and target accounts are already bootstrapped per the
[README quickstart](../README.md#quickstart). Commands use the AWS
documentation placeholder account ids (`111111111111`, `222222222222`,
`123456789012`); substitute your real ids locally — never commit them.

## Prerequisites checklist

- [ ] Tooling account applied (`terraform/tooling-account/`) — pipeline role and
      CodePipeline exist.
- [ ] Each target account applied (`terraform/target-account/`) — deployer role
      and CodeDeploy app exist.
- [ ] A CodeConnections connection to your Git provider exists and shows status
      **Available** (authorize the OAuth handshake in the console once).
- [ ] Your service runs on ECS (Fargate) behind an ALB with a prod listener and
      a separate test listener (8443).

## Step 1 — Add the deploy descriptors to your service repo

The pipeline is drop-in: it reuses your service's own build/test/deploy
entrypoints and only needs two descriptors checked into the service repo.

1. Copy `pipelines/appspec.yml` into your service repo (commonly under
   `deploy/` or repo root). Set `ContainerName` / `ContainerPort` to match your
   task definition's container.
2. Provide a build entrypoint the buildspecs can find. The buildspecs look,
   in order, for:
   - a `Makefile` target (`build`, `test`, `integration-test`, `deploy`), then
   - `package.json` scripts (`build`, `test`, `test:integration`), then
   - a no-op fallback so the pipeline still runs for a sources-only repo.

Example `Makefile` in the service repo:

```makefile
build:            ; npm ci && npm run build
test:             ; npm test
integration-test: ; npm run test:integration
deploy:           ; ./deploy/deploy.sh "$(ENV)"
```

## Step 2 — Point the tooling module at the service repo

In `terraform/tooling-account/terraform.tfvars`:

```hcl
# The CodeConnections connection ARN (must be "Available").
source_connection_arn = "arn:aws:codeconnections:us-east-1:123456789012:connection/<uuid>"

# owner/repo of the SERVICE repository (not this infra repo).
source_repository_id = "<your-github-org>/your-service"
source_branch        = "main"

# The accounts the pipeline may deploy into.
target_accounts = {
  dev     = "111111111111"
  staging = "222222222222"
  prod    = "123456789012"
}
```

Re-apply the tooling module:

```bash
cd terraform/tooling-account
terraform init && terraform apply
```

## Step 3 — Choose the promotion path

`deployment_stages` declares the ordered path. Every `name` must be a key in
`target_accounts`. To add a `qa` ring before staging, for example:

```hcl
deployment_stages = [
  { name = "dev",     manual_approval = false, integration_test = true },
  { name = "qa",      manual_approval = false, integration_test = true },
  { name = "staging", manual_approval = true,  integration_test = true },
  { name = "prod",    manual_approval = true,  integration_test = false },
]
```

(Adding `qa` also means applying `terraform/target-account/` in a `qa` account
with `environment = "qa"`. Note that `environment` validates to
`dev | staging | prod` by default — extend that validation list if you add
rings.)

## Step 4 — Confirm the cross-account trust

The deploy stage assumes each target account's deployer role and then calls
`sts:get-caller-identity`, failing fast if it is not in the expected account.
You can dry-run the assume-role from the tooling account:

```bash
# Read the deployer role ARNs the pipeline is allowed to assume:
terraform -chdir=terraform/tooling-account output deployer_role_arns

# Verify one of them is assumable with your tooling credentials:
aws sts assume-role \
  --role-arn "arn:aws:iam::111111111111:role/multi-acct-cicd-deployer" \
  --role-session-name onboarding-check >/dev/null && echo "assume-role OK"
```

If you enabled `external_id` on the target module, pass the same
`--external-id` here and configure it on the pipeline action.

## Step 5 — Trigger and watch

Push a commit to `source_branch`. Then:

1. Watch the pipeline in the CodePipeline console (or via
   `aws codepipeline get-pipeline-state`).
2. The first approval pauses before staging — approve it once dev integration
   tests are green.
3. Before prod traffic shifts, `scripts/canary-validator.sh` probes the green
   task set on the test listener:

   ```bash
   scripts/canary-validator.sh \
     --base-url https://green.test.example.invalid:8443 \
     --health-path /healthz \
     --expected-version "$(git rev-parse --short HEAD)"
   ```

## Step 6 — Rehearse a rollback (recommended)

Before you depend on auto-rollback in prod, prove it works in a lower
environment:

```bash
scripts/test-rollback.sh \
  --application   my-service-cd \
  --deployment-group my-service-dg \
  --cluster       my-service-dev \
  --service       my-service \
  --bad-image     123456789012.dkr.ecr.us-east-1.amazonaws.com/app:rollback-canary
```

A passing run deploys a deliberately-broken task definition and asserts that
CodeDeploy restores the previous task set.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Source stage stuck / `connection not available` | CodeConnections handshake not authorized | Open the connection in the console and click *Update pending connection*. |
| Deploy stage fails at `sts assume-role` | Trust policy / `external_id` mismatch | Re-apply the target module; confirm `tooling_account_id` and any `external_id`. |
| Deploy lands in the wrong account | `target_accounts` map mismatch | The deploy buildspec aborts on an account mismatch by design — fix the map and re-apply. |
| Approval never notifies | `approval_sns_topic_arn` empty | Set the topic ARN (or use the managed notifications topic) and re-apply. |
| Prod shift proceeds despite a sick green | Canary hook not wired | Confirm `appspec.yml` lists `CodeDeployHook_AfterAllowTestTraffic`. |
