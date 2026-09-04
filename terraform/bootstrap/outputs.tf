output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
