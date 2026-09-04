variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "alb_security_group_id" {
  type = string
}

variable "target_group_arn" {
  type = string
}

variable "container_image" {
  description = "Full image URI including tag, e.g. <account>.dkr.ecr.<region>.amazonaws.com/finzla-app:sha-abc123"
  type        = string
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "app_env" {
  description = "Value for the APP_ENV environment variable (dev/staging/prod)."
  type        = string
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "assign_public_ip" {
  description = "Never true — tasks must stay in private subnets. Kept as an explicit variable rather than hard-coded so it is visible/reviewable, not so it gets flipped."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
