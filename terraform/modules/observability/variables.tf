variable "name" {
  type = string
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "alert_email" {
  description = "Email address subscribed to the alerts SNS topic. Leave empty to skip the subscription (still creates the topic)."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
