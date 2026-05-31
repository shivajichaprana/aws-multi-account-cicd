# Provider and Terraform version constraints for the tooling-account root module.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
    # Used to package the Slack-notifier Lambda from inline source at plan time.
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
  }

  # Configure a remote backend per environment, e.g.:
  #
  #   terraform {
  #     backend "s3" {
  #       bucket         = "<your-tfstate-bucket-name>"
  #       key            = "aws-multi-account-cicd/tooling/terraform.tfstate"
  #       region         = "us-east-1"
  #       dynamodb_table = "<your-tflock-table-name>"
  #       encrypt        = true
  #     }
  #   }
  #
  # Left unconfigured here so the module can be validated without backend access.
}
