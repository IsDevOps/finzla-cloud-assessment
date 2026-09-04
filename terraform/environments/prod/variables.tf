variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "container_image" {
  type    = string
  default = "public.ecr.aws/docker/library/nginx:stable"
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "alert_email" {
  type    = string
  default = ""
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS. Required in prod — see README (no plain-HTTP production traffic)."
  type        = string
  default     = ""
}
