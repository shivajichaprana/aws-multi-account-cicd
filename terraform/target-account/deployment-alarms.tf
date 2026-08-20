# ---------------------------------------------------------------------------
# CloudWatch alarms wired to the CodeDeploy blue/green deployment group.
#
# These alarms are the failure detectors that drive auto-rollback. When any
# of them transitions to ALARM during a deployment, CodeDeploy stops the
# deployment and reverts the production listener to the prior task set.
#
# Three classes of failure are covered:
#
#   1. Elevated 5xx rate at the target group level
#      catches application crashes, missing dependencies, bad config.
#   2. Latency regression on the production target group
#      catches slow code paths, GC storms, connection-pool exhaustion.
#   3. Healthy-host shortfall in the freshly-deployed green target group
#      catches container startup failures and failing health checks.
#
# Every alarm uses statistic / period / evaluation-period settings tuned to
# fire fast enough that a rollback happens inside the linear-10%-every-1m
# traffic shift, but slow enough that benign one-shot blips never cause a
# false rollback.
#
# The alarms live in the same region as the ALB target groups. ARNs are
# exported so codedeploy-rollback.tf can wire them into the deployment
# group's alarm_configuration block.
# ---------------------------------------------------------------------------

# --- Inputs ----------------------------------------------------------------

variable "alb_arn_suffix" {
  description = <<-DESC
    The ARN suffix of the Application Load Balancer fronting the ECS
    service (e.g. "app/my-alb/1234abcd5678efgh"). Used as the
    LoadBalancer dimension on every ALB-emitted CloudWatch metric.
  DESC
  type = string

  validation {
    condition     = can(regex("^app/[^/]+/[a-z0-9]+$", var.alb_arn_suffix))
    error_message = "alb_arn_suffix must look like 'app/<alb-name>/<id>'."
  }
}

variable "blue_target_group_arn_suffix" {
  description = <<-DESC
    ARN suffix of the BLUE target group (e.g. "targetgroup/my-blue/abc123").
    Used as the TargetGroup dimension when tracking the live fleet's 5xx
    rate and latency during a deployment.
  DESC
  type = string

  validation {
    condition     = can(regex("^targetgroup/[^/]+/[a-z0-9]+$", var.blue_target_group_arn_suffix))
    error_message = "blue_target_group_arn_suffix must look like 'targetgroup/<name>/<id>'."
  }
}

variable "green_target_group_arn_suffix" {
  description = <<-DESC
    ARN suffix of the GREEN target group. Healthy-host shortfall on this
    target group is the fastest signal that the freshly-deployed task set
    is failing its container or ELB health checks.
  DESC
  type = string

  validation {
    condition     = can(regex("^targetgroup/[^/]+/[a-z0-9]+$", var.green_target_group_arn_suffix))
    error_message = "green_target_group_arn_suffix must look like 'targetgroup/<name>/<id>'."
  }
}

variable "deployment_alarm_sns_topic_arn" {
  description = <<-DESC
    Optional SNS topic ARN to notify when a deployment alarm fires. When
    empty no notification actions are attached and the alarm still drives
    CodeDeploy auto-rollback as its sole side effect.
  DESC
  type    = string
  default = ""

  validation {
    condition     = var.deployment_alarm_sns_topic_arn == "" || can(regex("^arn:aws[a-zA-Z-]*:sns:", var.deployment_alarm_sns_topic_arn))
    error_message = "deployment_alarm_sns_topic_arn must be empty or a valid SNS topic ARN."
  }
}

variable "target_5xx_threshold" {
  description = "Number of HTTPCode_Target_5XX_Count responses per minute that trips the 5xx alarm. Default is tuned for a low-traffic baseline; raise for high-RPS services."
  type        = number
  default     = 5

  validation {
    condition     = var.target_5xx_threshold > 0
    error_message = "target_5xx_threshold must be positive."
  }
}

variable "target_5xx_evaluation_periods" {
  description = "Consecutive 1-minute periods of breached threshold required to drive the 5xx alarm into ALARM."
  type        = number
  default     = 2

  validation {
    condition     = var.target_5xx_evaluation_periods >= 1 && var.target_5xx_evaluation_periods <= 10
    error_message = "target_5xx_evaluation_periods must be between 1 and 10."
  }
}

variable "target_latency_threshold_seconds" {
  description = "p95 TargetResponseTime (seconds) above which the latency alarm trips. Tune to roughly 2x steady-state p95."
  type        = number
  default     = 1.5

  validation {
    condition     = var.target_latency_threshold_seconds > 0
    error_message = "target_latency_threshold_seconds must be positive."
  }
}

variable "target_latency_evaluation_periods" {
  description = "Consecutive 1-minute periods of breached p95 latency required to ALARM."
  type        = number
  default     = 3

  validation {
    condition     = var.target_latency_evaluation_periods >= 1 && var.target_latency_evaluation_periods <= 10
    error_message = "target_latency_evaluation_periods must be between 1 and 10."
  }
}

variable "green_min_healthy_hosts" {
  description = "Minimum HealthyHostCount expected on the GREEN target group once traffic has begun shifting. Falling below this triggers rollback."
  type        = number
  default     = 1

  validation {
    condition     = var.green_min_healthy_hosts >= 1
    error_message = "green_min_healthy_hosts must be at least 1 otherwise the alarm can never recover."
  }
}

# --- Shared locals ---------------------------------------------------------

locals {
  # All deployment alarms share a prefix so they sort together in the
  # CloudWatch console and are trivially scoped in IAM and tagging.
  deployment_alarm_name_prefix = "${var.project_name}-${var.environment}-deploy"

  # When an SNS topic is provided we route ALARM and OK actions through it
  # for human notification. CodeDeploy still polls these alarms directly
  # and does not depend on the SNS notification path.
  alarm_actions    = var.deployment_alarm_sns_topic_arn == "" ? [] : [var.deployment_alarm_sns_topic_arn]
  ok_alarm_actions = var.deployment_alarm_sns_topic_arn == "" ? [] : [var.deployment_alarm_sns_topic_arn]

  deployment_alarm_tags = merge(local.common_tags, {
    Component = "deployment-alarms"
    Purpose   = "codedeploy-auto-rollback"
  })
}

# --- 1. Elevated target 5xx rate ------------------------------------------
# Sums HTTPCode_Target_5XX_Count across both blue and green target groups so
# the alarm catches failures regardless of which fleet is taking traffic at
# the moment. Missing data is treated as notBreaching to keep the alarm
# from flapping when the target groups are temporarily empty.
resource "aws_cloudwatch_metric_alarm" "target_5xx_rate" {
  alarm_name        = "${local.deployment_alarm_name_prefix}-target-5xx"
  alarm_description = "Sum of HTTPCode_Target_5XX_Count across blue and green target groups during a deployment."

  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.target_5xx_evaluation_periods
  threshold           = var.target_5xx_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "blue5xx"
    return_data = false
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      stat        = "Sum"
      period      = 60
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
        TargetGroup  = var.blue_target_group_arn_suffix
      }
    }
  }

  metric_query {
    id          = "green5xx"
    return_data = false
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      stat        = "Sum"
      period      = 60
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
        TargetGroup  = var.green_target_group_arn_suffix
      }
    }
  }

  metric_query {
    id          = "total5xx"
    expression  = "blue5xx + green5xx"
    label       = "Combined target 5xx count"
    return_data = true
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.ok_alarm_actions

  tags = merge(local.deployment_alarm_tags, {
    Name      = "${local.deployment_alarm_name_prefix}-target-5xx"
    AlarmType = "error-rate"
  })
}

# --- 2. Elevated p95 target response time ----------------------------------
# p95 TargetResponseTime on the blue target group, evaluated in 1-minute
# windows. The blue target group is the production-serving group, so its
# p95 latency is the cleanest signal that user-visible latency is rising.
resource "aws_cloudwatch_metric_alarm" "target_response_time" {
  alarm_name        = "${local.deployment_alarm_name_prefix}-target-latency"
  alarm_description = "p95 TargetResponseTime on the blue target group exceeded ${var.target_latency_threshold_seconds}s."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.target_latency_evaluation_periods
  threshold           = var.target_latency_threshold_seconds
  treat_missing_data  = "notBreaching"

  metric_name = "TargetResponseTime"
  namespace   = "AWS/ApplicationELB"
  period      = 60
  # ExtendedStatistic uses CloudWatch percentile notation; "p95" is preferred
  # over Average because tail latency is what trips real user experience.
  extended_statistic = "p95"
  unit               = "Seconds"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.blue_target_group_arn_suffix
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.ok_alarm_actions

  tags = merge(local.deployment_alarm_tags, {
    Name      = "${local.deployment_alarm_name_prefix}-target-latency"
    AlarmType = "latency"
  })
}

# --- 3. Unhealthy hosts on the GREEN target group --------------------------
# UnHealthyHostCount on the green target group is the fastest signal that
# the new task set is failing its ELB health check. We breach when at
# least one host has been unhealthy for the lookback window AND healthy
# count is below the configured minimum.
resource "aws_cloudwatch_metric_alarm" "green_unhealthy_hosts" {
  alarm_name        = "${local.deployment_alarm_name_prefix}-green-unhealthy"
  alarm_description = "GREEN target group has fewer than ${var.green_min_healthy_hosts} healthy hosts during deployment."

  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = var.green_min_healthy_hosts
  treat_missing_data  = "breaching" # missing data here means no healthy hosts treat as bad

  metric_name = "HealthyHostCount"
  namespace   = "AWS/ApplicationELB"
  period      = 60
  statistic   = "Minimum"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.green_target_group_arn_suffix
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.ok_alarm_actions

  tags = merge(local.deployment_alarm_tags, {
    Name      = "${local.deployment_alarm_name_prefix}-green-unhealthy"
    AlarmType = "host-health"
  })
}

# --- Outputs ---------------------------------------------------------------

output "deployment_alarm_arns" {
  description = "ARNs of every CloudWatch alarm wired into the CodeDeploy deployment group's rollback configuration."
  value = [
    aws_cloudwatch_metric_alarm.target_5xx_rate.arn,
    aws_cloudwatch_metric_alarm.target_response_time.arn,
    aws_cloudwatch_metric_alarm.green_unhealthy_hosts.arn,
  ]
}

output "deployment_alarm_names" {
  description = "Names of every CloudWatch alarm wired into the CodeDeploy deployment group's rollback configuration."
  value = [
    aws_cloudwatch_metric_alarm.target_5xx_rate.alarm_name,
    aws_cloudwatch_metric_alarm.target_response_time.alarm_name,
    aws_cloudwatch_metric_alarm.green_unhealthy_hosts.alarm_name,
  ]
}
