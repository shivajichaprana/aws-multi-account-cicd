# ---------------------------------------------------------------------------
# EventBridge pipeline events (tooling account)
#
# CodeStar Notifications already cover the broad pipeline lifecycle, but two
# events deserve a tailored, actionable message rather than a generic one:
#
#   * a manual approval is waiting  -> page approvers with a direct console link
#   * the pipeline execution failed -> page on-call with the failing pipeline
#
# Both rules are scoped to THIS pipeline (detail.pipeline filter) so they stay
# silent for any other pipeline in the account, and both fan into the same
# notifications SNS topic defined in notifications.tf. An input transformer
# rewrites the raw event into a one-line human-readable message; no Lambda is
# needed for the transform.
# ---------------------------------------------------------------------------

variable "enable_eventbridge_notifications" {
  description = "Create EventBridge rules that send tailored approval-request and pipeline-failure messages to the notifications topic."
  type        = bool
  default     = true
}

locals {
  eventbridge_enabled = var.enable_eventbridge_notifications

  # Region-aware deep link to the pipeline view (where approvals are actioned).
  pipeline_console_url = "https://${data.aws_region.current.name}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.this.name}/view?region=${data.aws_region.current.name}"
}

# ---------------------------------------------------------------------------
# Rule 1 — a manual-approval action has STARTED (i.e. approval is required).
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "approval_needed" {
  count = local.eventbridge_enabled ? 1 : 0

  name        = "${var.project_name}-approval-needed"
  description = "Fires when ${aws_codepipeline.this.name} pauses for a manual approval."

  event_pattern = jsonencode({
    source = ["aws.codepipeline"]
    "detail-type" = ["CodePipeline Action Execution State Change"]
    detail = {
      pipeline = [aws_codepipeline.this.name]
      state    = ["STARTED"]
      type = {
        category = ["Approval"]
      }
    }
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-approval-needed" })
}

resource "aws_cloudwatch_event_target" "approval_needed_sns" {
  count = local.eventbridge_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.approval_needed[0].name
  target_id = "notifications-sns"
  arn       = aws_sns_topic.notifications.arn

  input_transformer {
    input_paths = {
      pipeline = "$.detail.pipeline"
      stage    = "$.detail.stage"
      action   = "$.detail.action"
      account  = "$.account"
      region   = "$.region"
      time     = "$.time"
    }

    # The template must render to valid JSON; a single quoted string yields a
    # plain-text SNS message that reads cleanly in email and Slack alike.
    input_template = <<-TEMPLATE
      "[ACTION NEEDED] Pipeline <pipeline> is awaiting manual approval at stage <stage> (action <action>) in account <account> (<region>) at <time>. Approve or reject here: ${local.pipeline_console_url}"
    TEMPLATE
  }
}

# ---------------------------------------------------------------------------
# Rule 2 — the pipeline execution FAILED.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "pipeline_failed" {
  count = local.eventbridge_enabled ? 1 : 0

  name        = "${var.project_name}-pipeline-failed"
  description = "Fires when an execution of ${aws_codepipeline.this.name} fails."

  event_pattern = jsonencode({
    source = ["aws.codepipeline"]
    "detail-type" = ["CodePipeline Pipeline Execution State Change"]
    detail = {
      pipeline = [aws_codepipeline.this.name]
      state    = ["FAILED"]
    }
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-pipeline-failed" })
}

resource "aws_cloudwatch_event_target" "pipeline_failed_sns" {
  count = local.eventbridge_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.pipeline_failed[0].name
  target_id = "notifications-sns"
  arn       = aws_sns_topic.notifications.arn

  input_transformer {
    input_paths = {
      pipeline    = "$.detail.pipeline"
      executionId = "$.detail.execution-id"
      account     = "$.account"
      region      = "$.region"
      time        = "$.time"
    }

    input_template = <<-TEMPLATE
      "[FAILED] Pipeline <pipeline> execution <executionId> failed in account <account> (<region>) at <time>. Investigate: ${local.pipeline_console_url}"
    TEMPLATE
  }
}

# --- Outputs ----------------------------------------------------------------
output "eventbridge_rule_names" {
  description = "Names of the EventBridge rules wired to the notifications topic (empty when disabled)."
  value = local.eventbridge_enabled ? [
    aws_cloudwatch_event_rule.approval_needed[0].name,
    aws_cloudwatch_event_rule.pipeline_failed[0].name,
  ] : []
}
