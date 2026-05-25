# Account-agnostic data sources and shared locals for the target-account module.
data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  target_account_id = data.aws_caller_identity.current.account_id
  partition         = data.aws_partition.current.partition

  # The single trusted principal: the pipeline role in the tooling account.
  pipeline_role_arn = "arn:${local.partition}:iam::${var.tooling_account_id}:role/${var.pipeline_role_name}"

  common_tags = merge(
    {
      Project     = var.project_name
      Component   = "target-account"
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags,
  )
}
