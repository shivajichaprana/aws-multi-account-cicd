# Architecture & design decisions

This document explains *why* the pipeline is shaped the way it is. For a quick
visual, see the diagrams in the [README](../README.md); for hands-on wiring of a
new service, see [onboarding-new-service.md](onboarding-new-service.md).

## 1. Goals and constraints

| Goal | How it is met |
|------|---------------|
| Blast-radius isolation between CI/CD and workloads | Pipeline, artifacts, and KMS keys live in a dedicated tooling account; workloads live in separate target accounts. |
| No standing cross-account credentials | The pipeline assumes a per-stage deployer role with short-lived STS credentials; nothing is long-lived. |
| Safe production releases | ECS blue/green with a test listener, linear canary, and alarm-driven auto-rollback. |
| Reproducible, auditable deploys | Everything is Terraform; artifacts carry SLSA provenance; promotion path is declarative. |
| Drop-in for any service repo | Buildspecs fall back to a service's own `Makefile`/`package.json` targets, so the pattern does not dictate a build system. |

## 2. Account topology

Two root modules, applied with different credentials:

- **`terraform/tooling-account/`** — applied once, in the tooling account.
  Creates the pipeline role, CodePipeline, the three CodeBuild projects
  (build / test / deploy), the KMS-encrypted artifact bucket, and the
  notification plumbing.
- **`terraform/target-account/`** — applied once per environment, in each
  target account. Creates the deployer role, its permissions boundary, the
  CodeDeploy application/deployment group, and the deployment alarms.

The two modules are intentionally **not** combined into a single multi-provider
apply. Keeping them separate means a target account can be bootstrapped, audited,
and destroyed independently, and an operator only ever holds one account's
credentials at a time.

## 3. The trust chain (ADR-001)

**Decision:** the deployer role's trust policy names the tooling account's
pipeline role ARN as the only principal, and the pipeline role's identity
policy grants `sts:AssumeRole` to exactly the deployer role ARNs — no
wildcards.

**Why:** a principal ARN in a trust policy does not require the role to exist at
policy-creation time, which is what lets us apply target accounts before the
tooling account. Naming concrete ARNs on both sides (rather than `"AWS": "*"` +
a condition, or a wildcarded resource) means the assume-role graph is fully
enumerable from Terraform state.

**Hardening knob:** `external_id` (target module) adds an `sts:ExternalId`
condition to the trust policy. Set the same value on the pipeline's assume-role
action to require a shared secret on every hop.

## 4. Permission boundaries (ADR-002)

**Decision:** every deployer role carries a managed **permissions boundary**, so
the *effective* permissions of the role are the intersection of its attached
policies and the boundary — even if a future change over-grants the attached
policy.

**Why:** the deployer role is the most powerful identity the pipeline touches in
a target account. The boundary is the backstop that guarantees a mis-edited
policy (or a compromised pipeline) cannot escalate beyond an explicitly approved
ceiling. Boundary changes are deliberately a separate, reviewable edit from
routine policy changes.

## 5. Build → test → deploy (ADR-003)

The pipeline is a single ordered promotion path driven by the
`deployment_stages` variable. Each entry is `{ name, manual_approval,
integration_test }`:

- **Build** runs `buildspec-build.yml`: resolves the commit, builds/packages,
  assembles the deploy bundle (appspec + metadata), and exports `IMAGE_TAG` /
  `GIT_COMMIT` for downstream actions.
- **Unit test** runs `buildspec-test.yml` with `TEST_SCOPE=unit` before any
  deploy; results publish to a CodeBuild report group.
- **Deploy** runs `buildspec-deploy.yml`, which **assumes the target account's
  deployer role** and verifies (`sts:get-caller-identity`) that it landed in the
  expected account before applying anything.
- **Integration test** (optional per stage) re-runs `buildspec-test.yml` with
  `TEST_SCOPE=integration` against the just-deployed environment.
- **Manual approval** (optional per stage) pauses the pipeline; an SNS topic can
  notify approvers.

**Why data-driven stages:** adding a `qa` environment or making `staging`
auto-promote is a tfvars edit, not a pipeline rewrite. The same Terraform
renders any linear promotion path.

## 6. Blue/green and canary (ADR-004)

ECS blue/green via CodeDeploy, with the lifecycle hooks declared in
`pipelines/appspec.yml`:

```
BeforeInstall -> AfterInstall -> AfterAllowTestTraffic -> BeforeAllowTraffic -> AfterAllowTraffic
```

The **primary validation gate** is `AfterAllowTestTraffic`: the green task set is
reachable only on the test listener (8443), so `scripts/canary-validator.sh` can
run health, smoke, and latency-budget probes while real users are still on blue.
A failed hook stops the deployment before any prod traffic shifts.

Production uses a **linear-10-percent-every-1-minute** traffic shift, so a
regression that slips past the test gate still only reaches a small fraction of
users before alarms fire.

## 7. Auto-rollback (ADR-005)

The CodeDeploy deployment group is wired to CloudWatch alarms (5xx rate,
p95 latency, unhealthy host count). When an alarm trips during a deployment,
CodeDeploy aborts and restores the blue task set automatically. The behaviour is
verified — not assumed — by `scripts/test-rollback.sh`, which deliberately
deploys a known-bad task definition and asserts that the service is restored.

## 8. Supply-chain provenance (ADR-006)

`pipelines/generate-provenance.sh` emits an in-toto statement carrying a
SLSA Provenance v1.0 predicate for each build artifact, populated from the
metadata CodeBuild exposes (builder ARN, resolved source commit, build
invocation). The statement subject is the artifact's SHA-256 digest, so a
verifier can confirm the provenance describes exactly the bytes being deployed.
When image signing is configured, the statement is the predicate handed to
`cosign attest`.

## 9. Threat model (abridged)

| Threat | Mitigation |
|--------|------------|
| Compromised pipeline pivots into a workload account | Deployer role is the only assumable principal, bounded by a permissions boundary; optional `external_id`. |
| Over-broad policy edit escalates deployer privileges | Permissions boundary caps effective permissions regardless of attached policy. |
| Bad build reaches all prod users | Test-listener canary gate + linear 10%/min shift + alarm-driven rollback. |
| Tampered artifact deployed | SHA-256-pinned SLSA provenance; artifact bucket encrypted with KMS and cross-account-read-only. |
| Leaked account identifiers / state | `.gitignore` excludes `*.tfvars`, state, and generated reports; examples use AWS placeholder account ids only. |

## 10. What this repo intentionally does not do

- It does not create the CodeConnections connection (the OAuth handshake needs a
  human); you pass an already-`Available` connection ARN.
- It does not define the application's own build system; buildspecs defer to the
  service repo's `Makefile`/`package.json`.
- It does not manage Organizations/account creation; it assumes accounts exist.
