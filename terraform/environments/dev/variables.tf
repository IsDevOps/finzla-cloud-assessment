variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "container_image" {
  description = "Full ECR image URI:tag to deploy. Overridden by CI on each deploy; the placeholder here only matters for the very first `terraform apply` before any image has been pushed."
  type        = string
  default     = "public.ecr.aws/docker/library/nginx:stable"
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
  description = "ACM certificate ARN for HTTPS. Empty = HTTP only (fine for dev without a domain)."
  type        = string
  default     = ""
}
