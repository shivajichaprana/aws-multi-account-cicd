# ---------------------------------------------------------------------------
# CodeDeploy — Blue/Green deployment for ECS
#
# Provisions the CodeDeploy application, deployment group, and deployment
# configuration used to roll the target account's ECS service from the "blue"
# task set to "green" with a linear, automatically-validated canary.
#
# Traffic shifting:
#   - The production ALB listener (TCP 443) serves user traffic and is the
#     listener CodeDeploy shifts between blue and green target groups.
#   - A second "test" listener (TCP 8443) lets validation hooks reach the
#     freshly-deployed green task set without exposing it to real users.
#
# Cadence:
#   - A custom CodeDeployDefault-style deployment configuration shifts 10% of
#     traffic every minute. The full shift completes in roughly ten minutes,
#     with the bake/termination window allowing time for alarms to trip.
#
# Rollback wiring:
#   - The deployment group is alarm-aware; the actual CloudWatch alarms and
#     auto-rollback configuration are layered in by the next day's commit
#     (deployment-alarms.tf + codedeploy-rollback.tf). Until then, rollback
#     is still available via the manual stop-deployment + redeploy-previous
#     CodeDeploy controls and is exercised by scripts/canary-validator.sh.
# ---------------------------------------------------------------------------

locals {
  # Constant resource names, derived once so downstream files (alarms,
  # rollback config) can re-reference them without duplicating logic.
  codedeploy_app_name               = "${var.project_name}-${var.environment}"
  codedeploy_deployment_group_name  = "${var.project_name}-${var.environment}-bluegreen"
  codedeploy_service_role_name      = "${var.project_name}-${var.environment}-codedeploy-svc"
  codedeploy_deployment_config_name = "${var.project_name}-${var.environment}-Linear10PercentEvery1Minute"

  # Service / load balancer wiring. Defaults match the reference service in
  # examples/ecs-service; consumers point these at their own resources via
  # variables in terraform.tfvars.
  ecs_cluster_name_effective = var.ecs_cluster_name
  ecs_service_name_effective = var.ecs_service_name
  blue_target_group_name     = "${var.project_name}-${var.environment}-blue"
  green_target_group_name    = "${var.project_name}-${var.environment}-green"
}

# --- CodeDeploy service role ----------------------------------------------
# Lets the CodeDeploy ECS controller register task sets, swap listeners, and
# call back into ECS / ELB. The role is owned by the target account so the
# tooling-account pipeline never needs ELB or ECS-control permissions.
data "aws_iam_policy_document" "codedeploy_assume" {
  statement {
    sid     = "CodeDeployServiceAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy_service" {
  name                 = local.codedeploy_service_role_name
  description          = "Service role assumed by CodeDeploy for blue/green ECS deployments in ${var.environment}."
  assume_role_policy   = data.aws_iam_policy_document.codedeploy_assume.json
  permissions_boundary = aws_iam_policy.deployer_boundary.arn

  tags = merge(local.common_tags, {
    Name = local.codedeploy_service_role_name
    Role = "codedeploy-service"
  })
}

# AWS-managed policy for ECS blue/green. Resource scope is "*" by design;
# the permissions boundary above keeps the role within deployment-only
# surface area.
resource "aws_iam_role_policy_attachment" "codedeploy_ecs" {
  role       = aws_iam_role.codedeploy_service.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSCodeDeployRoleForECS"
}

# --- CloudWatch log group for deployment hook output ----------------------
# CodeDeploy itself emits to CloudTrail; this group is for the canary
# validator referenced from appspec.yml during traffic shifting. Retention
# is intentionally short — these logs are operational, not audit.
resource "aws_cloudwatch_log_group" "codedeploy_hooks" {
  name              = "/aws/codedeploy/${local.codedeploy_app_name}/hooks"
  retention_in_days = 30
  kms_key_id        = var.deployment_log_kms_key_arn != "" ? var.deployment_log_kms_key_arn : null

  tags = merge(local.common_tags, {
    Name = "/aws/codedeploy/${local.codedeploy_app_name}/hooks"
  })
}

# --- CodeDeploy application -----------------------------------------------
# One application per (project, environment). Compute platform is ECS so
# CodeDeploy knows to manage task sets rather than EC2 instances.
resource "aws_codedeploy_app" "this" {
  name             = local.codedeploy_app_name
  compute_platform = "ECS"

  tags = merge(local.common_tags, {
    Name = local.codedeploy_app_name
  })
}

# --- Custom deployment configuration --------------------------------------
# Linear 10% every 1 minute. AWS ships CodeDeployDefault.ECSLinear10Percent-
# Every1Minutes as a built-in, but defining our own makes the cadence
# explicit in code and lets us tune it per environment without touching the
# deployment group.
resource "aws_codedeploy_deployment_config" "linear_10_every_1m" {
  deployment_config_name = local.codedeploy_deployment_config_name
  compute_platform       = "ECS"

  traffic_routing_config {
    type = "TimeBasedLinear"

    time_based_linear {
      interval   = 1  # minutes between shifts
      percentage = 10 # percent of traffic shifted per interval
    }
  }
}

# --- Deployment group -----------------------------------------------------
# Binds the application to the live ECS service, target groups, and
# listeners. Auto-rollback alarms are populated by codedeploy-rollback.tf
# (next day); the lifecycle block below ignores those mutations so the two
# files can be applied independently without fighting each other.
resource "aws_codedeploy_deployment_group" "this" {
  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = local.codedeploy_deployment_group_name
  service_role_arn       = aws_iam_role.codedeploy_service.arn
  deployment_config_name = aws_codedeploy_deployment_config.linear_10_every_1m.deployment_config_name

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  blue_green_deployment_config {
    # The blue task set is terminated after a bake window. 10 minutes is long
    # enough for slow-burn alarms (5xx rate over 5m) to fire and trigger
    # rollback before the old version disappears.
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 10
    }

    deployment_ready_option {
      # Begin shifting traffic as soon as the green task set is healthy. Use
      # STOP_DEPLOYMENT here when a manual gate is wanted before traffic
      # moves; the pipeline already adds a manual approval before the prod
      # deploy stage, so a second hold would just slow things down.
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    # Spin up replacement tasks in place. COPY_AUTO_SCALING_GROUP is the
    # only valid value for the ECS compute platform.
    green_fleet_provisioning_option {
      action = "COPY_AUTO_SCALING_GROUP"
    }
  }

  ecs_service {
    cluster_name = local.ecs_cluster_name_effective
    service_name = local.ecs_service_name_effective
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [var.prod_listener_arn]
      }

      test_traffic_route {
        listener_arns = [var.test_listener_arn]
      }

      target_group {
        name = local.blue_target_group_name
      }

      target_group {
        name = local.green_target_group_name
      }
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  tags = merge(local.common_tags, {
    Name = local.codedeploy_deployment_group_name
  })

  lifecycle {
    # Alarm-driven rollback and the alarm list itself are managed by
    # codedeploy-rollback.tf (added in the follow-up commit). Without this
    # ignore_changes, the two files would drift each other on every apply.
    ignore_changes = [
      alarm_configuration,
    ]
  }
}

# --- ECS / load balancer wiring inputs ------------------------------------
# Kept here, beside the CodeDeploy resources that consume them, so a reader
# can understand the contract without jumping across files.
variable "ecs_cluster_name" {
  description = "Name of the ECS cluster that hosts the service being deployed."
  type        = string
  default     = "app-cluster"
}

variable "ecs_service_name" {
  description = "Name of the ECS service CodeDeploy manages task sets for."
  type        = string
  default     = "app-service"
}

variable "prod_listener_arn" {
  description = "ARN of the ALB listener serving production traffic. CodeDeploy shifts this listener between blue and green target groups."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:elasticloadbalancing:", var.prod_listener_arn))
    error_message = "prod_listener_arn must be a valid ALB listener ARN."
  }
}

variable "test_listener_arn" {
  description = "ARN of the ALB listener used for green-side validation hooks (not exposed to user traffic)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:elasticloadbalancing:", var.test_listener_arn))
    error_message = "test_listener_arn must be a valid ALB listener ARN."
  }
}

variable "deployment_log_kms_key_arn" {
  description = "Optional KMS key ARN used to encrypt the deployment-hook CloudWatch log group. Empty string disables encryption."
  type        = string
  default     = ""
}

# --- Outputs --------------------------------------------------------------
output "codedeploy_application_name" {
  description = "Name of the CodeDeploy ECS application. Pass this to the pipeline's CodeDeployToECS action."
  value       = aws_codedeploy_app.this.name
}

output "codedeploy_deployment_group_name" {
  description = "Name of the blue/green deployment group."
  value       = aws_codedeploy_deployment_group.this.deployment_group_name
}

output "codedeploy_deployment_config_name" {
  description = "Custom linear-10%-every-1-minute deployment configuration used by the group."
  value       = aws_codedeploy_deployment_config.linear_10_every_1m.deployment_config_name
}

output "codedeploy_service_role_arn" {
  description = "ARN of the CodeDeploy service role. Useful for cross-account console handoff."
  value       = aws_iam_role.codedeploy_service.arn
}
