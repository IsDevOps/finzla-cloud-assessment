# Same bucket as dev, different key — one state file per environment
# so a `terraform apply` in dev can never read or write prod's state,
# and the two environments can never accidentally share a lock.
terraform {
  backend "s3" {
    bucket       = "finzla-assessment-tfstate"
    key          = "prod/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
    encrypt      = true
  }
}
