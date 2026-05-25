# Default AWS provider for a single target account. The caller supplies that
# target account's credentials out of band.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
