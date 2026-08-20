# ---------------------------------------------------------------------------
# CodeDeploy alarm-driven auto-rollback configuration.
#
# This file finishes the rollback contract that codedeploy.tf intentionally
# leaves open. The deployment group there declares
#   lifecycle { ignore_changes = [alarm_configuration] }
# so that the alarm wiring lives here, beside the alarms themselves
# (deployment-alarms.tf), rather than being scattered across files.
#
# Mechanics:
#   - We use a terraform_data resource (built-in since Terraform 1.4) with
#     a local-exec provisioner that calls `aws deploy update-deployment-group`.
#   - The triggers_replace argument lists every input that should cause the
#     provisioner to re-run, so Terraform recomputes the live config any
#     time an alarm ARN, name, or rollback event list changes.
#   - The provisioner is intentionally idempotent: update-deployment-group
#     is a PUT-style API, so re-running with the same inputs is a no-op.
#
# Why not just inline alarm_configuration in codedeploy.tf?
#   CodeDeploy deployments can write to alarm_configuration during
#   deployment-time stop-on-alarm activity. Letting Terraform manage the
#   block directly would cause permanent drift after a real rollback.
#   The ignore_changes contract + this out-of-band update splits the
#   responsibility cleanly.
# ---------------------------------------------------------------------------

# --- Inputs ----------------------------------------------------------------

variable "ignore_poll_alarm_failure" {
  description = <<-DESC
    When true, CodeDeploy continues a deployment even if it cannot poll
    one of the configured alarms. Default false matches the safer
    behaviour: an unreachable alarm fails closed and stops the deployment.
  DESC
  type    = bool
  default = false
}

variable "rollback_events" {
  description = <<-DESC
    List of events that trigger CodeDeploy auto-rollback. Allowed values:
    DEPLOYMENT_FAILURE, DEPLOYMENT_STOP_ON_ALARM, DEPLOYMENT_STOP_ON_REQUEST.
    The default rolls back on any failure or alarm trip but leaves manual
    stop requests untouched so an operator can stop without auto-revert.
  DESC
  type    = list(string)
  default = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]

  validation {
    condition = alltrue([
      for ev in var.rollback_events :
      contains(["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM", "DEPLOYMENT_STOP_ON_REQUEST"], ev)
    ])
    error_message = "rollback_events entries must be DEPLOYMENT_FAILURE, DEPLOYMENT_STOP_ON_ALARM, or DEPLOYMENT_STOP_ON_REQUEST."
  }

  validation {
    condition     = length(var.rollback_events) > 0
    error_message = "rollback_events must list at least one event; otherwise auto-rollback is silently disabled."
  }
}

variable "aws_cli_path" {
  description = "Path to the aws CLI binary used by the local-exec provisioner. Override when running in a hermetic build image."
  type        = string
  default     = "aws"
}

# --- JSON payloads ---------------------------------------------------------
# Pre-computed once so the provisioner command line stays short and the
# triggers_replace keys hash on stable strings rather than nested objects.
locals {
  rollback_alarm_configuration_json = jsonencode({
    enabled                = true
    ignorePollAlarmFailure = var.ignore_poll_alarm_failure
    alarms = [
      { name = aws_cloudwatch_metric_alarm.target_5xx_rate.alarm_name },
      { name = aws_cloudwatch_metric_alarm.target_response_time.alarm_name },
      { name = aws_cloudwatch_metric_alarm.green_unhealthy_hosts.alarm_name },
    ]
  })

  auto_rollback_configuration_json = jsonencode({
    enabled = true
    events  = var.rollback_events
  })
}

# --- Out-of-band sync of alarm + rollback configuration --------------------
# terraform_data + local-exec is the standard Terraform idiom for managing
# a sub-attribute of a resource that is otherwise lifecycle-ignored.
resource "terraform_data" "deployment_group_rollback_sync" {
  # Re-trigger the provisioner whenever any input changes.
  triggers_replace = [
    aws_codedeploy_app.this.name,
    aws_codedeploy_deployment_group.this.deployment_group_name,
    local.rollback_alarm_configuration_json,
    local.auto_rollback_configuration_json,
    var.aws_region,
  ]

  # Capture the inputs so they are available inside the provisioner without
  # interpolating Terraform references inline (which would re-expand the
  # JSON quotes on every run and is harder to read in CI logs).
  input = {
    application_name      = aws_codedeploy_app.this.name
    deployment_group_name = aws_codedeploy_deployment_group.this.deployment_group_name
    region                = var.aws_region
    aws_cli_path          = var.aws_cli_path
    alarm_configuration   = local.rollback_alarm_configuration_json
    auto_rollback         = local.auto_rollback_configuration_json
  }

  # local-exec runs the AWS CLI against the *target* account; the caller is
  # expected to have already assumed the deployer role (or equivalent) when
  # invoking terraform apply.
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      "${self.input.aws_cli_path}" deploy update-deployment-group \
        --region "${self.input.region}" \
        --application-name "${self.input.application_name}" \
        --current-deployment-group-name "${self.input.deployment_group_name}" \
        --alarm-configuration '${self.input.alarm_configuration}' \
        --auto-rollback-configuration '${self.input.auto_rollback}'
      echo "deployment group ${self.input.deployment_group_name}: alarm + rollback configuration synced"
    EOT
  }

  # Reset alarm/auto-rollback config back to a known-clean state on destroy
  # so the deployment group does not linger with stale alarm references.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    on_failure  = continue
    command     = <<-EOT
      set -euo pipefail
      "${self.input.aws_cli_path}" deploy update-deployment-group \
        --region "${self.input.region}" \
        --application-name "${self.input.application_name}" \
        --current-deployment-group-name "${self.input.deployment_group_name}" \
        --alarm-configuration '{"enabled":false,"alarms":[]}' \
        --auto-rollback-configuration '{"enabled":false}'
      echo "deployment group ${self.input.deployment_group_name}: alarm + rollback configuration cleared"
    EOT
  }

  depends_on = [
    aws_codedeploy_deployment_group.this,
    aws_cloudwatch_metric_alarm.target_5xx_rate,
    aws_cloudwatch_metric_alarm.target_response_time,
    aws_cloudwatch_metric_alarm.green_unhealthy_hosts,
  ]
}

# --- Outputs ---------------------------------------------------------------

output "auto_rollback_events" {
  description = "Event list that triggers CodeDeploy auto-rollback. Useful for the test-rollback script to assert against."
  value       = var.rollback_events
}

output "rollback_alarm_configuration_json" {
  description = "Effective alarm configuration JSON applied to the deployment group. Captured for audit and drift detection."
  value       = local.rollback_alarm_configuration_json
}
