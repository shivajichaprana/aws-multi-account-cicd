output "target_account_id" {
  description = "Account id this target module is deployed into."
  value       = local.target_account_id
}

output "region" {
  description = "Region this target module is deployed into."
  value       = data.aws_region.current.name
}
