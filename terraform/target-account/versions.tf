# Provider and Terraform version constraints for the target-account root module.
# This module is applied independently in each target account (dev/staging/prod).
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
  }

  # Configure a remote backend per target account, e.g.:
  #
  #   terraform {
  #     backend "s3" {
  #       bucket  = "<your-tfstate-bucket-name>"
  #       key     = "aws-multi-account-cicd/target/dev/terraform.tfstate"
  #       region  = "us-east-1"
  #       encrypt = true
  #     }
  #   }
}
