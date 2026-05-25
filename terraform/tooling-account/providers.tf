# Default AWS provider for the tooling account. The caller supplies credentials
# for the tooling account (profile / assumed role / OIDC) out of band.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
