# Remote state: S3 for the state file itself (versioned + encrypted,
# see terraform/bootstrap), native S3 locking so two people/pipelines
# running `terraform apply` at once fail fast instead of corrupting
# state. The bucket and table are created once by terraform/bootstrap
# and never managed by this environment's own state.
terraform {
  backend "s3" {
    bucket       = "finzla-assessment-tfstate"
    key          = "dev/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
    encrypt      = true
  }
}
