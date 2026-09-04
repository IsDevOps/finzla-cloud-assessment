output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "ecs_cluster_name" {
  value = module.ecs_service.cluster_name
}

output "ecs_service_name" {
  value = module.ecs_service.service_name
}

output "github_actions_deploy_role_arn" {
  description = "Put this in the GitHub Environment's AWS_DEPLOY_ROLE_ARN variable/secret."
  value       = module.github_oidc.role_arn
}

output "dashboard_name" {
  value = module.observability.dashboard_name
}
