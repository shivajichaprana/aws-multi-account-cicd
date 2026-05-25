variable "aws_region" {
  description = "Region in which the tooling-account pipeline resources are created."
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

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,48}$", var.project_name))
    error_message = "project_name must be 3-49 chars, lowercase alphanumeric and hyphens."
  }
}

variable "target_accounts" {
  description = <<-DESC
    Map of environment name to the 12-digit AWS account id of the corresponding
    target account. The tooling pipeline role is granted sts:AssumeRole into the
    deployer role of each of these accounts.
  DESC
  type        = map(string)

  validation {
    condition     = alltrue([for id in values(var.target_accounts) : can(regex("^[0-9]{12}$", id))])
    error_message = "Every target account id must be exactly 12 digits."
  }

  validation {
    condition     = length(var.target_accounts) > 0
    error_message = "At least one target account must be supplied."
  }
}

variable "pipeline_role_name" {
  description = "Name of the IAM role assumed by CodePipeline in the tooling account."
  type        = string
  default     = "multi-acct-cicd-pipeline"
}

variable "deployer_role_name" {
  description = <<-DESC
    Name of the deployer role that exists in every target account. Used to build
    the assume-role target ARNs. Must match deployer_role_name in the
    target-account module.
  DESC
  type        = string
  default     = "multi-acct-cicd-deployer"
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
