# ---------------------------------------------------------------------------
# Pipeline notifications (tooling account)
#
# Fan-out hub for everything an operator should hear about:
#
#   CodeStar Notifications (pipeline + build state)
#   EventBridge rules (approval requests — see eventbridge-events.tf)
#                                  |
#                                  v
#                    SNS topic  <project>-notifications   (CMK-encrypted)
#                       |                 |
#                       v                 v
#               email subscriptions   Slack-notifier Lambda --> Slack webhook
#
# A single SNS topic is the one place producers publish to and the one place
# subscribers attach to. Slack delivery is done with a small Lambda that reads
# the incoming-webhook URL from SSM Parameter Store at runtime (no secret ever
# touches Terraform state or the repo); it is only created when a parameter
# name is supplied, so the topic is fully usable with email alone.
# ---------------------------------------------------------------------------

# --- Inputs (scoped to the notifications feature) ---------------------------
variable "notification_emails" {
  description = "Email addresses subscribed to the pipeline notifications topic. Each receives a confirmation request on first apply."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.notification_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "Every entry in notification_emails must be a valid email address."
  }
}

variable "slack_webhook_ssm_parameter" {
  description = <<-DESC
    Name of a pre-existing SSM Parameter Store SecureString that holds the Slack
    incoming-webhook URL (e.g. "/aws-multi-account-cicd/slack/webhook-url").
    Leave empty to skip Slack delivery entirely (the SNS topic and email
    subscriptions still work). The parameter must be created out of band so its
    secret value never lands in Terraform state.
  DESC
  type    = string
  default = ""

  validation {
    condition     = var.slack_webhook_ssm_parameter == "" || can(regex("^/?[a-zA-Z0-9_.\\-/]+$", var.slack_webhook_ssm_parameter))
    error_message = "slack_webhook_ssm_parameter must be empty or a valid SSM parameter name."
  }
}

variable "notification_detail_type" {
  description = "CodeStar Notifications detail level: BASIC or FULL."
  type        = string
  default     = "FULL"

  validation {
    condition     = contains(["BASIC", "FULL"], var.notification_detail_type)
    error_message = "notification_detail_type must be BASIC or FULL."
  }
}

variable "notify_on_build_failures" {
  description = "Also raise a CodeStar notification rule on the build CodeBuild project (failed/succeeded), not just the pipeline."
  type        = bool
  default     = true
}

locals {
  # Slack delivery is wired up only when a webhook parameter is provided.
  slack_enabled = var.slack_webhook_ssm_parameter != ""

  # Normalised SSM parameter ARN the notifier Lambda is allowed to read.
  slack_param_name = trimprefix(var.slack_webhook_ssm_parameter, "/")
  slack_param_arn  = "arn:${local.partition}:ssm:${data.aws_region.current.name}:${local.tooling_account_id}:parameter/${local.slack_param_name}"
}

# ---------------------------------------------------------------------------
# CMK used to encrypt the notifications topic.
#
# The topic carries pipeline metadata (names, stages, commit ids) rather than
# secrets, but encrypting it keeps the whole control plane consistent and lets
# the topic satisfy an "SNS encrypted with a CMK" control. The key policy must
# additionally permit every service that publishes through the topic to
# generate a data key, or those publishes fail with KMSAccessDenied.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "notifications_kms" {
  statement {
    sid       = "EnableAccountAdmin"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.tooling_account_id}:root"]
    }
  }

  # Publishing services need data-key + decrypt to put messages on the topic.
  statement {
    sid    = "AllowPublishingServicesUseOfTheKey"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey*",
      "kms:Decrypt",
    ]
    resources = ["*"]

    principals {
      type = "Service"
      identifiers = [
        "codestar-notifications.amazonaws.com",
        "events.amazonaws.com",
        "cloudwatch.amazonaws.com",
        "sns.amazonaws.com",
      ]
    }
  }
}

resource "aws_kms_key" "notifications" {
  description             = "${var.project_name} pipeline notifications topic encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.notifications_kms.json

  tags = merge(local.common_tags, { Name = "${var.project_name}-notifications" })
}

resource "aws_kms_alias" "notifications" {
  name          = "alias/${var.project_name}-notifications"
  target_key_id = aws_kms_key.notifications.key_id
}

# ---------------------------------------------------------------------------
# The notifications topic.
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "notifications" {
  name              = "${var.project_name}-notifications"
  kms_master_key_id = aws_kms_key.notifications.arn

  tags = merge(local.common_tags, { Name = "${var.project_name}-notifications" })
}

# Allow the in-account producers (CodeStar Notifications, EventBridge,
# CloudWatch) to publish, plus standard owner control. SourceAccount /
# SourceOwner conditions stop a confused-deputy from another account driving
# our topic.
data "aws_iam_policy_document" "notifications_topic" {
  statement {
    sid       = "OwnerFullControl"
    effect    = "Allow"
    actions   = ["sns:Publish", "sns:Subscribe", "sns:SetTopicAttributes", "sns:GetTopicAttributes"]
    resources = [aws_sns_topic.notifications.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.tooling_account_id}:root"]
    }
  }

  statement {
    sid       = "AllowServicePublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.notifications.arn]

    principals {
      type = "Service"
      identifiers = [
        "codestar-notifications.amazonaws.com",
        "events.amazonaws.com",
        "cloudwatch.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.tooling_account_id]
    }
  }
}

resource "aws_sns_topic_policy" "notifications" {
  arn    = aws_sns_topic.notifications.arn
  policy = data.aws_iam_policy_document.notifications_topic.json
}

# --- Email subscriptions ----------------------------------------------------
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.notification_emails)

  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = each.value
}

# ---------------------------------------------------------------------------
# CodeStar Notifications — pipeline state.
#
# Covers the full execution lifecycle plus the manual-approval signals so an
# approver is paged the moment the pipeline pauses for them.
# ---------------------------------------------------------------------------
resource "aws_codestarnotifications_notification_rule" "pipeline" {
  name        = "${var.project_name}-pipeline"
  detail_type = var.notification_detail_type
  resource    = aws_codepipeline.this.arn

  event_type_ids = [
    "codepipeline-pipeline-pipeline-execution-started",
    "codepipeline-pipeline-pipeline-execution-succeeded",
    "codepipeline-pipeline-pipeline-execution-failed",
    "codepipeline-pipeline-pipeline-execution-canceled",
    "codepipeline-pipeline-pipeline-execution-superseded",
    "codepipeline-pipeline-manual-approval-needed",
    "codepipeline-pipeline-manual-approval-succeeded",
    "codepipeline-pipeline-manual-approval-failed",
  ]

  target {
    type    = "SNS"
    address = aws_sns_topic.notifications.arn
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-pipeline" })

  depends_on = [aws_sns_topic_policy.notifications]
}

# --- CodeStar Notifications — build project (optional) ----------------------
resource "aws_codestarnotifications_notification_rule" "build" {
  count = var.notify_on_build_failures ? 1 : 0

  name        = "${var.project_name}-build"
  detail_type = var.notification_detail_type
  resource    = aws_codebuild_project.build.arn

  event_type_ids = [
    "codebuild-project-build-state-failed",
    "codebuild-project-build-state-succeeded",
  ]

  target {
    type    = "SNS"
    address = aws_sns_topic.notifications.arn
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-build" })

  depends_on = [aws_sns_topic_policy.notifications]
}

# ===========================================================================
# Slack delivery Lambda (created only when slack_webhook_ssm_parameter is set)
# ===========================================================================

# Package the handler from inline source so there is no committed build
# artifact. The zip is written under build/ (gitignored) at plan time.
data "archive_file" "slack_notifier" {
  count       = local.slack_enabled ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/build/slack-notifier.zip"

  source {
    filename = "index.py"
    content  = <<-PY
      """Forward SNS pipeline notifications to a Slack incoming webhook.

      The webhook URL is read from SSM Parameter Store at cold start, so the
      secret is never embedded in code, environment, or Terraform state. Both
      CodeStar Notifications payloads (JSON) and EventBridge-via-SNS payloads
      (plain strings) are handled.
      """
      import json
      import logging
      import os
      import urllib.request

      import boto3

      LOGGER = logging.getLogger()
      LOGGER.setLevel(logging.INFO)

      _SSM = boto3.client("ssm")
      _WEBHOOK_CACHE = {}


      def _webhook_url():
          """Return the cached webhook URL, fetching it from SSM once."""
          if "url" not in _WEBHOOK_CACHE:
              name = os.environ["SLACK_WEBHOOK_SSM_PARAM"]
              resp = _SSM.get_parameter(Name=name, WithDecryption=True)
              _WEBHOOK_CACHE["url"] = resp["Parameter"]["Value"]
          return _WEBHOOK_CACHE["url"]


      def _summarize(subject, message):
          """Build a compact Slack text block from an SNS record."""
          # CodeStar Notifications send a JSON document; EventBridge input
          # transformers send a plain string. Try JSON, fall back to raw text.
          try:
              parsed = json.loads(message)
          except (ValueError, TypeError):
              return subject or message

          detail = parsed.get("detail", parsed)
          pipeline = detail.get("pipeline") or parsed.get("detailType", "")
          state = detail.get("state", "")
          header = subject or "Pipeline notification"
          parts = [header]
          if pipeline:
              parts.append("pipeline=%s" % pipeline)
          if state:
              parts.append("state=%s" % state)
          return " | ".join(parts)


      def handler(event, _context):
          """Lambda entry point: fan SNS records out to Slack."""
          webhook = _webhook_url()
          for record in event.get("Records", []):
              sns = record.get("Sns", {})
              text = _summarize(sns.get("Subject", ""), sns.get("Message", ""))
              payload = json.dumps({"text": text}).encode("utf-8")
              req = urllib.request.Request(
                  webhook,
                  data=payload,
                  headers={"Content-Type": "application/json"},
                  method="POST",
              )
              with urllib.request.urlopen(req, timeout=8) as resp:
                  status = resp.getcode()
              if status >= 300:
                  raise RuntimeError("Slack webhook returned HTTP %s" % status)
              LOGGER.info("Delivered notification to Slack: %s", text)

          return {"delivered": len(event.get("Records", []))}
    PY
  }
}

data "aws_iam_policy_document" "slack_notifier_trust" {
  count = local.slack_enabled ? 1 : 0

  statement {
    sid     = "AllowLambda"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "slack_notifier" {
  count = local.slack_enabled ? 1 : 0

  name                  = "${var.project_name}-slack-notifier"
  description           = "Execution role for the Slack notifications Lambda."
  assume_role_policy    = data.aws_iam_policy_document.slack_notifier_trust[0].json
  force_detach_policies = true

  tags = merge(local.common_tags, { Name = "${var.project_name}-slack-notifier" })
}

resource "aws_cloudwatch_log_group" "slack_notifier" {
  count = local.slack_enabled ? 1 : 0

  name              = "/aws/lambda/${var.project_name}-slack-notifier"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Name = "${var.project_name}-slack-notifier" })
}

# Least-privilege: write its own logs and read exactly one SSM parameter.
data "aws_iam_policy_document" "slack_notifier" {
  count = local.slack_enabled ? 1 : 0

  statement {
    sid    = "WriteLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.slack_notifier[0].arn}:*"]
  }

  statement {
    sid       = "ReadSlackWebhookParameter"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [local.slack_param_arn]
  }

  # Decrypt the SecureString, but only when SSM is the calling service.
  statement {
    sid       = "DecryptSecureString"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "slack_notifier" {
  count = local.slack_enabled ? 1 : 0

  name   = "${var.project_name}-slack-notifier"
  role   = aws_iam_role.slack_notifier[0].id
  policy = data.aws_iam_policy_document.slack_notifier[0].json
}

resource "aws_lambda_function" "slack_notifier" {
  count = local.slack_enabled ? 1 : 0

  function_name    = "${var.project_name}-slack-notifier"
  description      = "Forwards SNS pipeline notifications to a Slack incoming webhook."
  role             = aws_iam_role.slack_notifier[0].arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.slack_notifier[0].output_path
  source_code_hash = data.archive_file.slack_notifier[0].output_base64sha256
  timeout          = 15
  memory_size      = 128

  environment {
    variables = {
      SLACK_WEBHOOK_SSM_PARAM = var.slack_webhook_ssm_parameter
    }
  }

  # Don't let a Slack outage build up an unbounded backlog of invocations.
  reserved_concurrent_executions = 5

  depends_on = [
    aws_iam_role_policy.slack_notifier,
    aws_cloudwatch_log_group.slack_notifier,
  ]

  tags = merge(local.common_tags, { Name = "${var.project_name}-slack-notifier" })
}

resource "aws_sns_topic_subscription" "slack" {
  count = local.slack_enabled ? 1 : 0

  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notifier[0].arn
}

resource "aws_lambda_permission" "slack_from_sns" {
  count = local.slack_enabled ? 1 : 0

  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.notifications.arn
}

# --- Outputs ----------------------------------------------------------------
output "notifications_topic_arn" {
  description = "ARN of the pipeline notifications SNS topic. Wire this into approval_sns_topic_arn to also notify on manual approvals."
  value       = aws_sns_topic.notifications.arn
}

output "slack_notifier_function_name" {
  description = "Name of the Slack-notifier Lambda, or null when Slack delivery is disabled."
  value       = local.slack_enabled ? aws_lambda_function.slack_notifier[0].function_name : null
}
