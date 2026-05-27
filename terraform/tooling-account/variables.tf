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

# ---------------------------------------------------------------------------
# Source / pipeline configuration (added with the CodePipeline + CodeBuild stack)
# ---------------------------------------------------------------------------

variable "source_connection_arn" {
  description = <<-DESC
    ARN of an existing CodeStar (CodeConnections) connection to the Git provider
    used as the pipeline source. The connection must be created and set to
    "Available" out of band (creating it via Terraform leaves it PENDING until a
    human authorizes the OAuth handshake in the console).
  DESC
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:code(star-connections|connections):[a-z0-9-]+:[0-9]{12}:connection/[0-9a-f-]+$", var.source_connection_arn))
    error_message = "source_connection_arn must be a valid CodeStar/CodeConnections connection ARN."
  }
}

variable "source_repository_id" {
  description = "Full source repository id in 'owner/repo' form, e.g. <your-github-org>/your-service."
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.source_repository_id))
    error_message = "source_repository_id must be in 'owner/repo' form."
  }
}

variable "source_branch" {
  description = "Branch that triggers the pipeline."
  type        = string
  default     = "main"
}

variable "artifact_bucket_name" {
  description = <<-DESC
    Optional explicit name for the artifact bucket. Leave empty to derive a
    globally-unique name of the form
    "<project>-artifacts-<tooling-account-id>-<region>".
  DESC
  type    = string
  default = ""
}

variable "approval_sns_topic_arn" {
  description = <<-DESC
    Optional SNS topic ARN to notify on manual-approval actions. When empty, the
    approval still pauses the pipeline but no SNS notification is sent. (A managed
    notifications topic is wired up later in the notifications module.)
  DESC
  type    = string
  default = ""

  validation {
    condition     = var.approval_sns_topic_arn == "" || can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:.+$", var.approval_sns_topic_arn))
    error_message = "approval_sns_topic_arn must be empty or a valid SNS topic ARN."
  }
}

variable "deployment_stages" {
  description = <<-DESC
    Ordered promotion path. Each entry names an environment (which must be a key
    in target_accounts), whether a manual approval is required before deploying
    to it, and whether an integration-test action runs against it after deploy.
  DESC
  type = list(object({
    name             = string
    manual_approval  = bool
    integration_test = bool
  }))

  default = [
    { name = "dev", manual_approval = false, integration_test = true },
    { name = "staging", manual_approval = true, integration_test = true },
    { name = "prod", manual_approval = true, integration_test = false },
  ]

  validation {
    condition     = length(var.deployment_stages) > 0
    error_message = "At least one deployment stage must be defined."
  }
}

variable "codebuild_compute_type" {
  description = "CodeBuild compute type for build/test/deploy projects."
  type        = string
  default     = "BUILD_GENERAL1_SMALL"

  validation {
    condition = contains([
      "BUILD_GENERAL1_SMALL",
      "BUILD_GENERAL1_MEDIUM",
      "BUILD_GENERAL1_LARGE",
      "BUILD_GENERAL1_2XLARGE",
    ], var.codebuild_compute_type)
    error_message = "codebuild_compute_type must be a valid CodeBuild compute type."
  }
}

variable "codebuild_image" {
  description = "Container image used by all CodeBuild projects."
  type        = string
  default     = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
}

variable "build_timeout_minutes" {
  description = "Per-build timeout in minutes."
  type        = number
  default     = 30

  validation {
    condition     = var.build_timeout_minutes >= 5 && var.build_timeout_minutes <= 480
    error_message = "build_timeout_minutes must be between 5 and 480."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention (days) for CodeBuild project log groups."
  type        = number
  default     = 365

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653,
    ], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch Logs retention value."
  }
}
