locals {
  name = "finzla-${var.environment}"
  azs  = ["${var.region}a", "${var.region}b"]
  tags = { Environment = var.environment }
}

module "vpc" {
  source = "../../modules/vpc"

  name                 = local.name
  azs                  = local.azs
  public_subnet_cidrs  = ["10.10.0.0/24", "10.10.1.0/24"]
  private_subnet_cidrs = ["10.10.10.0/24", "10.10.11.0/24"]
  single_nat_gateway   = true # dev: optimise for cost over AZ redundancy
  tags                 = local.tags
}

module "ecr" {
  source = "../../modules/ecr"

  name = local.name
  tags = local.tags
}

module "alb" {
  source = "../../modules/alb"

  name              = local.name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  certificate_arn   = var.certificate_arn
  tags              = local.tags
}

module "ecs_service" {
  source = "../../modules/ecs-service"

  name                  = local.name
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  alb_security_group_id = module.alb.security_group_id
  target_group_arn      = module.alb.target_group_arn
  container_image       = var.container_image
  app_env               = var.environment
  cpu                   = 256
  memory                = 512
  desired_count         = 1 # dev: single task is enough
  log_retention_days    = 14
  tags                  = local.tags
}

module "observability" {
  source = "../../modules/observability"

  name                    = local.name
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  ecs_cluster_name        = module.ecs_service.cluster_name
  ecs_service_name        = module.ecs_service.service_name
  alert_email             = var.alert_email
  tags                    = local.tags
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  name                    = "${local.name}-deploy"
  oidc_provider_arn       = data.aws_iam_openid_connect_provider.github.arn
  github_org              = var.github_org
  github_repo             = var.github_repo
  github_environment      = "development"
  ecr_repository_arn      = module.ecr.repository_arn
  ecs_cluster_arn         = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${module.ecs_service.cluster_name}"
  ecs_service_arn         = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:service/${module.ecs_service.cluster_name}/${module.ecs_service.service_name}"
  task_execution_role_arn = module.ecs_service.task_execution_role_arn
  task_role_arn           = module.ecs_service.task_role_arn
  tags                    = local.tags
}

data "aws_caller_identity" "current" {}

# Looked up rather than re-created — the OIDC provider is an
# account-wide singleton created once in terraform/bootstrap.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}
