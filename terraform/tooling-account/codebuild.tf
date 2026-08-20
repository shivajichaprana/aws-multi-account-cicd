# ---------------------------------------------------------------------------
# CodeBuild projects (tooling account)
#
# Four projects back the pipeline:
#   * build             — compile/package the application, emit the deploy bundle
#   * test              — fast unit tests + static analysis (TEST_SCOPE=unit)
#   * integration-test  — post-deploy integration suite (TEST_SCOPE=integration)
#   * deploy            — assumes the target-account deployer role and applies
#
# All projects share one service role whose only cross-account capability is
# sts:AssumeRole into the target deployer roles (the deploy project uses it; the
# others never call AssumeRole).
# ---------------------------------------------------------------------------

# --- CodeBuild service role -------------------------------------------------
data "aws_iam_policy_document" "codebuild_trust" {
  statement {
    sid     = "AllowCodeBuild"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.tooling_account_id]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name                  = "${var.project_name}-codebuild"
  description           = "Service role for the CICD CodeBuild projects."
  assume_role_policy    = data.aws_iam_policy_document.codebuild_trust.json
  force_detach_policies = true

  tags = merge(local.common_tags, { Name = "${var.project_name}-codebuild" })
}

# Logs + test reporting permissions for the build projects.
data "aws_iam_policy_document" "codebuild_base" {
  statement {
    sid    = "WriteBuildLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${local.partition}:logs:*:${local.tooling_account_id}:log-group:/aws/codebuild/${var.project_name}-*",
      "arn:${local.partition}:logs:*:${local.tooling_account_id}:log-group:/aws/codebuild/${var.project_name}-*:*",
    ]
  }

  statement {
    sid    = "PublishTestReports"
    effect = "Allow"
    actions = [
      "codebuild:CreateReportGroup",
      "codebuild:CreateReport",
      "codebuild:UpdateReport",
      "codebuild:BatchPutTestCases",
      "codebuild:BatchPutCodeCoverages",
    ]
    resources = ["arn:${local.partition}:codebuild:*:${local.tooling_account_id}:report-group/${var.project_name}-*"]
  }
}

resource "aws_iam_policy" "codebuild_base" {
  name        = "${var.project_name}-codebuild-base"
  description = "Baseline logging and test-reporting permissions for CodeBuild."
  policy      = data.aws_iam_policy_document.codebuild_base.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "codebuild_base" {
  role       = aws_iam_role.codebuild.name
  policy_arn = aws_iam_policy.codebuild_base.arn
}

# Reuse the shared artifact-bucket + KMS access policy defined in s3-artifacts.tf.
resource "aws_iam_role_policy_attachment" "codebuild_artifacts_access" {
  role       = aws_iam_role.codebuild.name
  policy_arn = aws_iam_policy.artifacts_access.arn
}

# The deploy project assumes the deployer role in the relevant target account.
data "aws_iam_policy_document" "codebuild_assume_deployers" {
  statement {
    sid       = "AssumeTargetDeployerRoles"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = values(local.deployer_role_arns)
  }
}

resource "aws_iam_policy" "codebuild_assume_deployers" {
  name        = "${var.project_name}-codebuild-assume-deployers"
  description = "Allows the deploy CodeBuild project to assume target-account deployer roles."
  policy      = data.aws_iam_policy_document.codebuild_assume_deployers.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "codebuild_assume_deployers" {
  role       = aws_iam_role.codebuild.name
  policy_arn = aws_iam_policy.codebuild_assume_deployers.arn
}

# --- Log groups -------------------------------------------------------------
locals {
  codebuild_projects = ["build", "test", "integration-test", "deploy"]
}

resource "aws_cloudwatch_log_group" "codebuild" {
  for_each = toset(local.codebuild_projects)

  name              = "/aws/codebuild/${var.project_name}-${each.value}"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Name = "${var.project_name}-${each.value}" })
}

# --- Build: compile, package, emit deploy bundle ----------------------------
resource "aws_codebuild_project" "build" {
  name           = "${var.project_name}-build"
  description    = "Builds and packages the application artifact."
  service_role   = aws_iam_role.codebuild.arn
  build_timeout  = var.build_timeout_minutes
  encryption_key = aws_kms_key.artifacts.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = var.codebuild_compute_type
    image           = var.codebuild_image
    type            = "LINUX_CONTAINER"
    privileged_mode = true # allow `docker build` for container artifacts

    environment_variable {
      name  = "ARTIFACT_BUCKET"
      value = aws_s3_bucket.artifacts.bucket
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/buildspec-build.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild["build"].name
      stream_name = "build"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-build" })
}

# --- Test: unit tests + static analysis -------------------------------------
resource "aws_codebuild_project" "test" {
  name           = "${var.project_name}-test"
  description    = "Runs unit tests and static analysis."
  service_role   = aws_iam_role.codebuild.arn
  build_timeout  = var.build_timeout_minutes
  encryption_key = aws_kms_key.artifacts.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = var.codebuild_compute_type
    image        = var.codebuild_image
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "TEST_SCOPE"
      value = "unit"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/buildspec-test.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild["test"].name
      stream_name = "test"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-test" })
}

# --- Integration test: runs against a freshly deployed environment ----------
resource "aws_codebuild_project" "integration_test" {
  name           = "${var.project_name}-integration-test"
  description    = "Runs the integration suite against a deployed environment."
  service_role   = aws_iam_role.codebuild.arn
  build_timeout  = var.build_timeout_minutes
  encryption_key = aws_kms_key.artifacts.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = var.codebuild_compute_type
    image        = var.codebuild_image
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "TEST_SCOPE"
      value = "integration"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/buildspec-test.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild["integration-test"].name
      stream_name = "integration-test"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-integration-test" })
}

# --- Deploy: assumes the target deployer role and applies the change --------
# Invoked once per environment by the pipeline with DEPLOY_ENV / DEPLOY_ROLE_ARN
# / TARGET_ACCOUNT_ID overridden per stage.
resource "aws_codebuild_project" "deploy" {
  name           = "${var.project_name}-deploy"
  description    = "Assumes the target-account deployer role and deploys the artifact."
  service_role   = aws_iam_role.codebuild.arn
  build_timeout  = var.build_timeout_minutes
  encryption_key = aws_kms_key.artifacts.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = var.codebuild_compute_type
    image        = var.codebuild_image
    type         = "LINUX_CONTAINER"

    # Placeholder values; CodePipeline overrides these per deploy stage.
    environment_variable {
      name  = "DEPLOY_ENV"
      value = "unset"
    }

    environment_variable {
      name  = "DEPLOY_ROLE_ARN"
      value = "unset"
    }

    environment_variable {
      name  = "TARGET_ACCOUNT_ID"
      value = "unset"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/buildspec-deploy.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild["deploy"].name
      stream_name = "deploy"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-deploy" })
}

output "codebuild_project_names" {
  description = "Names of the CodeBuild projects backing the pipeline."
  value = {
    build            = aws_codebuild_project.build.name
    test             = aws_codebuild_project.test.name
    integration_test = aws_codebuild_project.integration_test.name
    deploy           = aws_codebuild_project.deploy.name
  }
}

output "codebuild_role_arn" {
  description = "ARN of the shared CodeBuild service role."
  value       = aws_iam_role.codebuild.arn
}
