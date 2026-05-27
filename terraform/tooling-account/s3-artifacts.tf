# ---------------------------------------------------------------------------
# Pipeline artifact store (tooling account)
#
# A single, versioned, CMK-encrypted S3 bucket holds the artifacts that pass
# between pipeline stages. The KMS key and bucket policy both grant the
# target-account deployer roles read-only access so a cross-account deploy
# action can pull the build artifact it needs.
# ---------------------------------------------------------------------------

locals {
  # Derive a globally-unique bucket name when the caller does not pin one.
  artifact_bucket_name = (
    var.artifact_bucket_name != ""
    ? var.artifact_bucket_name
    : "${var.project_name}-artifacts-${local.tooling_account_id}-${data.aws_region.current.name}"
  )
}

# --- Customer-managed key used to encrypt artifacts at rest -----------------
data "aws_iam_policy_document" "artifacts_kms" {
  # Account administrators retain full control of the key.
  statement {
    sid       = "EnableAccountAdmin"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.tooling_account_id}:root"]
    }
  }

  # In-account pipeline + build roles may use the key for crypto operations.
  statement {
    sid    = "AllowPipelineAndBuildUse"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type = "AWS"
      identifiers = [
        aws_iam_role.pipeline.arn,
        aws_iam_role.codebuild.arn,
      ]
    }
  }

  # Cross-account deployer roles may only decrypt (to read artifacts).
  statement {
    sid    = "AllowTargetDeployersDecrypt"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = values(local.deployer_role_arns)
    }
  }
}

resource "aws_kms_key" "artifacts" {
  description             = "${var.project_name} pipeline artifact encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.artifacts_kms.json

  tags = merge(local.common_tags, { Name = "${var.project_name}-artifacts" })
}

resource "aws_kms_alias" "artifacts" {
  name          = "alias/${var.project_name}-artifacts"
  target_key_id = aws_kms_key.artifacts.key_id
}

# --- Artifact bucket --------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket = local.artifact_bucket_name

  # Artifacts are reproducible; allow Terraform to remove the bucket on destroy.
  force_destroy = true

  tags = merge(local.common_tags, { Name = local.artifact_bucket_name })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.artifacts.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  # Drop failed multipart uploads promptly.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Expire artifacts and their old versions so the bucket does not grow forever.
  rule {
    id     = "expire-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# --- Bucket policy: TLS-only + cross-account read ---------------------------
data "aws_iam_policy_document" "artifacts_bucket" {
  # Reject any request not made over TLS.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Allow each target-account deployer role to read artifacts during deploy.
  statement {
    sid    = "AllowTargetDeployersRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = values(local.deployer_role_arns)
    }
  }

  statement {
    sid       = "AllowTargetDeployersList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn]

    principals {
      type        = "AWS"
      identifiers = values(local.deployer_role_arns)
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts_bucket.json

  # Ensure the public-access block is in place before attaching a policy.
  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

# --- Shared in-account access policy (artifact bucket + KMS) ----------------
# Attached to both the pipeline role (here) and the CodeBuild role (in
# codebuild.tf). The pipeline-role module deliberately left these grants to be
# defined alongside the resources they reference.
data "aws_iam_policy_document" "artifacts_access" {
  statement {
    sid    = "ReadWriteArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:GetBucketAcl",
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  statement {
    sid    = "UseArtifactsKey"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.artifacts.arn]
  }
}

resource "aws_iam_policy" "artifacts_access" {
  name        = "${var.project_name}-artifacts-access"
  description = "Read/write the pipeline artifact bucket and use its KMS key."
  policy      = data.aws_iam_policy_document.artifacts_access.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "pipeline_artifacts_access" {
  role       = aws_iam_role.pipeline.name
  policy_arn = aws_iam_policy.artifacts_access.arn
}

output "artifact_bucket_name" {
  description = "Name of the pipeline artifact bucket."
  value       = aws_s3_bucket.artifacts.bucket
}

output "artifact_bucket_arn" {
  description = "ARN of the pipeline artifact bucket."
  value       = aws_s3_bucket.artifacts.arn
}

output "artifacts_kms_key_arn" {
  description = "ARN of the KMS key used to encrypt pipeline artifacts."
  value       = aws_kms_key.artifacts.arn
}
