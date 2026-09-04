variable "name" {
  description = "ECR repository name."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
