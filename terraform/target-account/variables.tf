variable "aws_region" {
  description = "Region in which the target-account deployment resources are created."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid AWS region, e.g. us-east-1."
  }
}

variable "project_name" {
  description = "Short project identifier used to name and tag resources."
  type        = string
  default     = "aws-multi-account-cicd"
}

variable "environment" {
  description = "Environment this target account represents."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "tooling_account_id" {
  description = "12-digit account id of the tooling account whose pipeline role may assume the deployer role."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.tooling_account_id))
    error_message = "tooling_account_id must be exactly 12 digits."
  }
}

variable "pipeline_role_name" {
  description = "Name of the pipeline role in the tooling account that is the sole trusted principal for the deployer role."
  type        = string
  default     = "multi-acct-cicd-pipeline"
}

variable "deployer_role_name" {
  description = "Name of the deployer role created in this target account. Must match deployer_role_name in the tooling module."
  type        = string
  default     = "multi-acct-cicd-deployer"
}

variable "permissions_boundary_name" {
  description = "Name of the managed policy used as the permissions boundary on the deployer role."
  type        = string
  default     = "multi-acct-cicd-deployer-boundary"
}

variable "external_id" {
  description = <<-DESC
    Optional shared secret required in the sts:AssumeRole call (sts:ExternalId).
    When non-empty, the deployer trust policy requires the caller to present it.
    Set the same value on the pipeline's assume-role action.
  DESC
  type      = string
  default   = ""
  sensitive = true
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
