variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name for Terraform remote state."
  type        = string
  default     = "finzla-assessment-tfstate"
}

variable "lock_table_name" {
  type    = string
  default = "finzla-assessment-tfstate-lock"
}
