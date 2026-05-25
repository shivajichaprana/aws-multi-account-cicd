# Account-agnostic data sources and shared locals for the tooling-account module.
data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  tooling_account_id = data.aws_caller_identity.current.account_id
  partition          = data.aws_partition.current.partition

  # Fully-qualified ARNs of the deployer role in each target account. These are
  # the only roles the pipeline role is permitted to assume.
  deployer_role_arns = {
    for env, account_id in var.target_accounts :
    env => "arn:${local.partition}:iam::${account_id}:role/${var.deployer_role_name}"
  }

  common_tags = merge(
    {
      Project   = var.project_name
      Component = "tooling-account"
      ManagedBy = "terraform"
    },
    var.tags,
  )
}
