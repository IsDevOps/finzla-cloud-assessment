# Bootstrap: creates the handful of account-wide resources that every
# environment's Terraform depends on, but which can't live in that
# same Terraform state (chicken-and-egg — the state bucket can't be
# stored in itself). Applied once, by hand, with local state, by
# someone with sufficient IAM privileges to create these resources:
#
#   cd terraform/bootstrap
#   terraform init
#   terraform apply
#
# After this, nobody needs those elevated privileges again — the
# per-environment deploy roles in modules/github-oidc are scoped far
# more narrowly and are what CI actually uses day to day.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }

  tags = { Purpose = "terraform-remote-state" }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = { Purpose = "terraform-state-locking" }
}

# One OIDC provider per AWS account, shared by every environment's
# deploy role (modules/github-oidc). GitHub rotates the signing
# certificate itself; AWS validates the token against GitHub's CA
# rather than this thumbprint, but the field is still required.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
