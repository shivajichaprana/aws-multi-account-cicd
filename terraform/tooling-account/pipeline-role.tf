# ---------------------------------------------------------------------------
# Pipeline role (tooling account)
#
# The single identity CodePipeline runs as. Its only cross-account capability
# is sts:AssumeRole into the named deployer role in each target account — it
# holds no standing permissions inside any target account.
# ---------------------------------------------------------------------------

# Trust policy: only the CodePipeline and CodeBuild services may assume this
# role, and only when the request originates from this tooling account
# (confused-deputy protection via aws:SourceAccount).
data "aws_iam_policy_document" "pipeline_trust" {
  statement {
    sid     = "AllowPipelineServices"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "codepipeline.amazonaws.com",
        "codebuild.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.tooling_account_id]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name                 = var.pipeline_role_name
  description          = "CodePipeline execution role; assumes deployer roles in target accounts."
  assume_role_policy   = data.aws_iam_policy_document.pipeline_trust.json
  max_session_duration = 3600
  force_detach_policies = true

  tags = merge(local.common_tags, { Name = var.pipeline_role_name })
}

# The only cross-account grant: assume the deployer role in each target account.
data "aws_iam_policy_document" "pipeline_assume_deployers" {
  statement {
    sid       = "AssumeTargetDeployerRoles"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = values(local.deployer_role_arns)
  }
}

resource "aws_iam_policy" "pipeline_assume_deployers" {
  name        = "${var.pipeline_role_name}-assume-deployers"
  description = "Allows the pipeline role to assume the deployer role in each target account."
  policy      = data.aws_iam_policy_document.pipeline_assume_deployers.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "pipeline_assume_deployers" {
  role       = aws_iam_role.pipeline.name
  policy_arn = aws_iam_policy.pipeline_assume_deployers.arn
}

# Minimal self-account permissions the pipeline needs to operate (emit logs).
# Artifact-bucket, KMS, and CodeBuild grants are added with those resources in
# their own modules.
data "aws_iam_policy_document" "pipeline_base" {
  statement {
    sid    = "WritePipelineLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:${local.partition}:logs:*:${local.tooling_account_id}:log-group:/aws/codepipeline/*"]
  }
}

resource "aws_iam_policy" "pipeline_base" {
  name        = "${var.pipeline_role_name}-base"
  description = "Baseline logging permissions for the pipeline role in the tooling account."
  policy      = data.aws_iam_policy_document.pipeline_base.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "pipeline_base" {
  role       = aws_iam_role.pipeline.name
  policy_arn = aws_iam_policy.pipeline_base.arn
}

output "pipeline_role_arn" {
  description = "ARN of the pipeline role; configure this as the trusted principal in each target account."
  value       = aws_iam_role.pipeline.arn
}

output "pipeline_role_name" {
  description = "Name of the pipeline role."
  value       = aws_iam_role.pipeline.name
}
