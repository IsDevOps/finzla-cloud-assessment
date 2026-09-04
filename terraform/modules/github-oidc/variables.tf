variable "name" {
  description = "Name for the deploy role, e.g. finzla-prod-deploy."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the account's token.actions.githubusercontent.com OIDC provider (created once in bootstrap/)."
  type        = string
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "github_environment" {
  description = "GitHub Environment name this role is scoped to (e.g. 'production'). The trust policy only accepts OIDC tokens carrying this exact environment claim, so a workflow run that was not dispatched against this GitHub Environment cannot assume the role at all — regardless of which repo or branch it came from."
  type        = string
}

variable "ecr_repository_arn" {
  type = string
}

variable "ecs_cluster_arn" {
  type = string
}

variable "ecs_service_arn" {
  type = string
}

variable "task_execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "terraform_state_bucket_arn" {
  description = "Optional: allow this role to also run terraform plan/apply for this environment against the shared state bucket. Leave null for a deploy-only role that cannot touch Terraform state."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
