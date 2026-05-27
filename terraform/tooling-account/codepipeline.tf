# ---------------------------------------------------------------------------
# CodePipeline (tooling account)
#
# Source -> Build -> Test -> [Approve] -> Deploy -> [IntegrationTest] per the
# promotion path declared in var.deployment_stages (default dev -> staging ->
# prod, with manual approval before staging and prod).
#
# Deploy actions run in the deploy CodeBuild project with DEPLOY_ROLE_ARN
# overridden per environment, so the actual change is applied by the
# target-account deployer role rather than by any standing tooling-account
# credential.
# ---------------------------------------------------------------------------

locals {
  # Expand the declarative promotion path into an ordered list of pipeline
  # stages. Each entry yields exactly one stage with one action.
  deploy_stage_actions = flatten([
    for s in var.deployment_stages : concat(
      # Optional manual approval gate before this environment.
      s.manual_approval ? [
        {
          stage_name    = "Approve-${title(s.name)}"
          action_name   = "Approve"
          category      = "Approval"
          provider_name = "Manual"
          inputs        = []
          config = (
            var.approval_sns_topic_arn != "" ?
            tomap({
              NotificationArn = var.approval_sns_topic_arn
              CustomData      = "Approve deployment to ${s.name}"
            }) :
            tomap({
              CustomData = "Approve deployment to ${s.name}"
            })
          )
        }
      ] : [],
      # Deploy to this environment via the deploy project.
      [
        {
          stage_name    = "Deploy-${title(s.name)}"
          action_name   = "Deploy"
          category      = "Build"
          provider_name = "CodeBuild"
          inputs        = ["build_output"]
          config = tomap({
            ProjectName = aws_codebuild_project.deploy.name
            EnvironmentVariables = jsonencode([
              { name = "DEPLOY_ENV", value = s.name, type = "PLAINTEXT" },
              { name = "DEPLOY_ROLE_ARN", value = local.deployer_role_arns[s.name], type = "PLAINTEXT" },
              { name = "TARGET_ACCOUNT_ID", value = var.target_accounts[s.name], type = "PLAINTEXT" },
            ])
          })
        }
      ],
      # Optional integration test against the just-deployed environment.
      s.integration_test ? [
        {
          stage_name    = "IntegrationTest-${title(s.name)}"
          action_name   = "IntegrationTest"
          category      = "Test"
          provider_name = "CodeBuild"
          inputs        = ["build_output"]
          config = tomap({
            ProjectName = aws_codebuild_project.integration_test.name
            EnvironmentVariables = jsonencode([
              { name = "TARGET_ENV", value = s.name, type = "PLAINTEXT" },
            ])
          })
        }
      ] : [],
    )
  ])
}

# --- Extra permissions the pipeline role needs to drive the pipeline --------
data "aws_iam_policy_document" "pipeline_ops" {
  # Pull source through the CodeStar/CodeConnections connection.
  statement {
    sid    = "UseSourceConnection"
    effect = "Allow"
    actions = [
      "codestar-connections:UseConnection",
      "codeconnections:UseConnection",
    ]
    resources = [var.source_connection_arn]
  }

  # Start and inspect the CodeBuild projects used as pipeline actions.
  statement {
    sid    = "RunBuildProjects"
    effect = "Allow"
    actions = [
      "codebuild:StartBuild",
      "codebuild:StopBuild",
      "codebuild:BatchGetBuilds",
      "codebuild:BatchGetProjects",
    ]
    resources = [
      aws_codebuild_project.build.arn,
      aws_codebuild_project.test.arn,
      aws_codebuild_project.integration_test.arn,
      aws_codebuild_project.deploy.arn,
    ]
  }

  # Notify approvers when an approval topic is configured.
  dynamic "statement" {
    for_each = var.approval_sns_topic_arn != "" ? [var.approval_sns_topic_arn] : []
    content {
      sid       = "NotifyApprovers"
      effect    = "Allow"
      actions   = ["sns:Publish"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_policy" "pipeline_ops" {
  name        = "${var.pipeline_role_name}-ops"
  description = "Lets the pipeline role use the source connection and run build projects."
  policy      = data.aws_iam_policy_document.pipeline_ops.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "pipeline_ops" {
  role       = aws_iam_role.pipeline.name
  policy_arn = aws_iam_policy.pipeline_ops.arn
}

# --- The pipeline -----------------------------------------------------------
resource "aws_codepipeline" "this" {
  name          = var.project_name
  role_arn      = aws_iam_role.pipeline.arn
  pipeline_type = "V1"

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"

    encryption_key {
      id   = aws_kms_key.artifacts.arn
      type = "KMS"
    }
  }

  # 1. Source — pull the branch through the connection on every change.
  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn        = var.source_connection_arn
        FullRepositoryId     = var.source_repository_id
        BranchName           = var.source_branch
        OutputArtifactFormat = "CODE_ZIP"
        DetectChanges        = "true"
      }
    }
  }

  # 2. Build — compile/package and emit the deploy bundle.
  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  # 3. Test — fast unit tests + static analysis before anything is deployed.
  stage {
    name = "Test"

    action {
      name            = "UnitTest"
      category        = "Test"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.test.name
      }
    }
  }

  # 4..N. Promotion path (approve / deploy / integration-test per environment).
  dynamic "stage" {
    for_each = local.deploy_stage_actions

    content {
      name = stage.value.stage_name

      action {
        name            = stage.value.action_name
        category        = stage.value.category
        owner           = "AWS"
        provider        = stage.value.provider_name
        version         = "1"
        run_order       = 1
        input_artifacts = stage.value.inputs
        configuration   = stage.value.config
      }
    }
  }

  tags = merge(local.common_tags, { Name = var.project_name })

  depends_on = [
    aws_iam_role_policy_attachment.pipeline_ops,
    aws_iam_role_policy_attachment.pipeline_artifacts_access,
    aws_s3_bucket_policy.artifacts,
  ]
}

output "pipeline_name" {
  description = "Name of the CodePipeline."
  value       = aws_codepipeline.this.name
}

output "pipeline_arn" {
  description = "ARN of the CodePipeline."
  value       = aws_codepipeline.this.arn
}
