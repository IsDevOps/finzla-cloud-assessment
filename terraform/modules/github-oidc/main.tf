# Deploy role assumable ONLY by a GitHub Actions run that:
#   1. presents a valid OIDC token from token.actions.githubusercontent.com
#   2. for this exact repo
#   3. running against this exact GitHub Environment (e.g. "production")
#
# GitHub Environments carry their own protection rules (required
# reviewers, restricted to specific branches). Because the environment
# name is baked into the trust condition's `sub` claim, a workflow run
# that hasn't gone through that environment's approval simply cannot
# obtain a matching token — the role can't be assumed at all, let
# alone used. This is what stops another repo, a compromised workflow
# in a different job, or an individual developer's own credentials
# from deploying to production: there are no long-lived AWS keys to
# steal, and the short-lived token this role issues is only ever
# handed to a run that already cleared the environment gate.

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:environment:${var.github_environment}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = var.name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600 # AWS minimum; still short-lived relative to a permanent access key

  tags = var.tags
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action has no resource-level permissions in IAM
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [var.ecr_repository_arn]
  }

  statement {
    sid       = "RegisterTaskDefinition"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"] # RegisterTaskDefinition does not support resource-level restriction
  }

  statement {
    sid       = "UpdateService"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [var.ecs_service_arn]
  }

  statement {
    sid       = "DescribeCluster"
    actions   = ["ecs:DescribeClusters"]
    resources = [var.ecs_cluster_arn]
  }

  statement {
    sid       = "ListAndDescribeTasksForHealthCheck"
    actions   = ["ecs:ListTasks", "ecs:DescribeTasks"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.ecs_cluster_arn]
    }
  }

  # The deploy role must be able to hand the task/execution roles to
  # ECS when registering a task definition, but not to any other
  # principal, and not to any other role in the account.
  statement {
    sid       = "PassEcsRolesOnly"
    actions   = ["iam:PassRole"]
    resources = [var.task_execution_role_arn, var.task_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "${var.name}-permissions"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

# Optional: only granted when a state bucket ARN is supplied, so a
# pure "deploy image" role never needs Terraform state access at all.
data "aws_iam_policy_document" "terraform_state" {
  count = var.terraform_state_bucket_arn == null ? 0 : 1

  statement {
    sid       = "StateBucket"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.terraform_state_bucket_arn}/*"]
  }

  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [var.terraform_state_bucket_arn]
  }
}

resource "aws_iam_role_policy" "terraform_state" {
  count  = var.terraform_state_bucket_arn == null ? 0 : 1
  name   = "${var.name}-terraform-state"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.terraform_state[0].json
}
