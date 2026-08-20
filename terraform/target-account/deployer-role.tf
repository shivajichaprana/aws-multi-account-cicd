# ---------------------------------------------------------------------------
# Deployer role (target account)
#
# Created once per target account (dev/staging/prod). It is the sole identity
# the tooling-account pipeline role may assume here. Everything it can ever do
# is capped by an attached permissions boundary, independent of the policies
# later granted to it.
# ---------------------------------------------------------------------------

locals {
  # Constructed (not referenced) ARN of the boundary policy, so the boundary
  # document can deny tampering with itself without a dependency cycle.
  boundary_policy_arn = "arn:${local.partition}:iam::${local.target_account_id}:policy/${var.permissions_boundary_name}"
}

# --- Permissions boundary -------------------------------------------------
# Upper bound on the deployer role's effective permissions. The role's granted
# permissions are intersected with this; nothing outside it is ever allowed.
data "aws_iam_policy_document" "deployer_boundary" {
  # Services a deployment legitimately needs.
  statement {
    sid    = "AllowDeploymentServices"
    effect = "Allow"
    actions = [
      "cloudformation:*",
      "ecs:*",
      "codedeploy:*",
      "elasticloadbalancing:*",
      "application-autoscaling:*",
      "ec2:Describe*",
      "ec2:CreateTags",
      "logs:*",
      "cloudwatch:*",
      "sns:Publish",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "secretsmanager:GetSecretValue",
      "lambda:InvokeFunction",
      "lambda:GetFunction",
    ]
    resources = ["*"]
  }

  # Read artifacts and decrypt with the pipeline's KMS key.
  statement {
    sid    = "AllowArtifactReadAndDecrypt"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  # Constrained IAM: read, plus PassRole only to ECS/CodeDeploy service roles.
  statement {
    sid    = "AllowConstrainedIam"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:AttachRolePolicy",
      "iam:PassRole",
    ]
    resources = ["*"]
  }

  # Hard guardrails — explicit denies always win over any allow.
  statement {
    sid    = "DenyIdentityAndOrgEscalation"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:AttachUserPolicy",
      "iam:PutUserPolicy",
      "iam:UpdateAssumeRolePolicy",
      "organizations:*",
      "account:*",
    ]
    resources = ["*"]
  }

  # A role created by a deployment must itself carry this boundary, preventing
  # boundary-escape via newly minted roles.
  statement {
    sid    = "DenyRoleCreateWithoutBoundary"
    effect = "Deny"
    actions = [
      "iam:CreateRole",
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_policy_arn]
    }
  }

  # Nobody assuming this role may detach or rewrite the boundary itself.
  statement {
    sid    = "DenyBoundaryTampering"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
      "iam:CreatePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
    ]
    resources = [local.boundary_policy_arn]
  }
}

resource "aws_iam_policy" "deployer_boundary" {
  name        = var.permissions_boundary_name
  description = "Permissions boundary capping what the cross-account deployer role can do."
  policy      = data.aws_iam_policy_document.deployer_boundary.json
  tags        = local.common_tags
}

# --- Trust policy ---------------------------------------------------------
# Only the tooling-account pipeline role may assume the deployer role. When an
# external id is configured, it is also required.
data "aws_iam_policy_document" "deployer_trust" {
  statement {
    sid     = "AllowToolingPipelineRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [local.pipeline_role_arn]
    }

    dynamic "condition" {
      for_each = toset(var.external_id == "" ? [] : [var.external_id])
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [condition.value]
      }
    }
  }
}

# --- Deployer role --------------------------------------------------------
resource "aws_iam_role" "deployer" {
  name                  = var.deployer_role_name
  description           = "Cross-account deployer role assumed by the tooling pipeline (${var.environment})."
  assume_role_policy    = data.aws_iam_policy_document.deployer_trust.json
  permissions_boundary  = aws_iam_policy.deployer_boundary.arn
  max_session_duration  = 3600
  force_detach_policies = true

  tags = merge(local.common_tags, { Name = var.deployer_role_name })
}

# Granted deployment permissions (always intersected with the boundary above).
data "aws_iam_policy_document" "deployer_permissions" {
  statement {
    sid    = "Deploy"
    effect = "Allow"
    actions = [
      "cloudformation:CreateStack",
      "cloudformation:UpdateStack",
      "cloudformation:DeleteStack",
      "cloudformation:DescribeStacks",
      "cloudformation:DescribeStackEvents",
      "cloudformation:DescribeStackResources",
      "cloudformation:GetTemplate",
      "cloudformation:ValidateTemplate",
      "ecs:RegisterTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:UpdateService",
      "ecs:CreateService",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:RegisterApplicationRevision",
      "codedeploy:GetApplicationRevision",
      "elasticloadbalancing:Describe*",
      "logs:DescribeLogGroups",
      "logs:CreateLogGroup",
      "cloudwatch:DescribeAlarms",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  # PassRole limited to ECS task and execution roles for this project.
  statement {
    sid       = "PassExecutionRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.target_account_id}:role/${var.project_name}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com", "codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "deployer_permissions" {
  name        = "${var.deployer_role_name}-permissions"
  description = "Deployment permissions granted to the deployer role (bounded by the permissions boundary)."
  policy      = data.aws_iam_policy_document.deployer_permissions.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "deployer_permissions" {
  role       = aws_iam_role.deployer.name
  policy_arn = aws_iam_policy.deployer_permissions.arn
}

output "deployer_role_arn" {
  description = "ARN of the deployer role in this target account."
  value       = aws_iam_role.deployer.arn
}

output "permissions_boundary_arn" {
  description = "ARN of the permissions boundary applied to the deployer role."
  value       = aws_iam_policy.deployer_boundary.arn
}
