output "tooling_account_id" {
  description = "Account id the tooling module is deployed into."
  value       = local.tooling_account_id
}

output "region" {
  description = "Region the tooling module is deployed into."
  value       = data.aws_region.current.name
}

output "deployer_role_arns" {
  description = "Map of environment to the target-account deployer role ARN the pipeline may assume."
  value       = local.deployer_role_arns
}
