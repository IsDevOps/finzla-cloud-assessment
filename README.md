# Finzla Cloud & Platform Engineer — Technical Assessment

A small HTTP service, deployed to AWS on ECS Fargate behind an ALB, provisioned entirely with
Terraform, and shipped through a GitHub Actions pipeline that authenticates to AWS with OIDC
(no long-lived AWS keys anywhere in this repo).

Architecture diagram: [docs/architecture.md](docs/architecture.md).

## Repository layout

```
app/                          FastAPI service: GET /health, GET /version
Dockerfile                    Multi-stage-ish, non-root, HEALTHCHECK
terraform/
  bootstrap/                  One-time, hand-applied: state bucket, lock, GitHub OIDC provider
  modules/
    vpc/                      Public + private subnets, IGW, NAT, routing
    ecr/                      Image repo, scan-on-push, lifecycle policy
    alb/                      Public ALB, security group, target group, HTTP->HTTPS redirect
    ecs-service/              Cluster, task def, service, task/execution IAM roles, log group, secret
    github-oidc/              Per-environment deploy role trusted only for that GitHub Environment
    observability/            SNS alerts topic, 2 CloudWatch alarms, a dashboard
  environments/
    dev/                      Root module wiring the above for dev
    prod/                     Same, sized and separated for prod
.github/workflows/
  pr.yml                      fmt / validate / plan, app build+test, Trivy image scan, checkov
  deploy.yml                  build -> push -> deploy (dev, then prod behind approval) -> health check
docs/architecture.md          Diagram + request-path walkthrough
```

## 1. Application

`GET /health` returns `200 OK` with a small JSON body. `GET /version` returns `APP_VERSION`,
`GIT_COMMIT` and `BUILD_NUMBER`, all injected as environment variables at build/deploy time — no
version is hard-coded. `APP_ENV` selects the running environment. All logging goes through Python's
`logging` module to stdout/stderr (never to a file), which is what lets the ECS `awslogs` driver ship
it to CloudWatch without any code-level integration. No credentials or secrets appear in source —
the one secret the app is wired to read (`APP_SECRET`) comes from Secrets Manager via the ECS
`secrets` mechanism, injected by the task's execution role, never from a plaintext environment
variable.

Run locally:

```bash
docker build -t finzla-assessment:local .
docker run -p 8000:8000 -e APP_ENV=local finzla-assessment:local
curl localhost:8000/health
curl localhost:8000/version
```

## 2. AWS Architecture

**Chosen: ECS on Fargate**, not EKS.

- The workload is one stateless HTTP container with two endpoints. EKS brings a control plane to
  operate (or pay for), CNI/networking add-ons, cluster upgrades, and a steeper IAM model (IRSA) —
  all real costs with no corresponding benefit at this scale. Fargate removes host patching and
  capacity planning entirely; you describe a task, AWS runs it.
- ECS's native primitives map directly onto the assessment's requirements: `deployment_circuit_breaker`
  gives automatic rollback on failed health checks for free, and its IAM model (task role vs.
  execution role) gives a clean least-privilege split without extra tooling.
- **Rejected alternative: EKS.** It would make sense if this were one of many services sharing a
  cluster, using Kubernetes-specific tooling (Helm, operators, service mesh), or needing
  scheduling flexibility Fargate doesn't offer. None of that applies to a single small service, and
  the brief itself rewards "smaller, secure, well-understood" over unnecessary complexity.

The container is never exposed directly: it runs in a private subnet with a security group that only
accepts traffic from the ALB's security group (see [docs/architecture.md](docs/architecture.md) for
the full request path and diagram).

### Terraform structure

- **Logical structure**: reusable modules (`vpc`, `ecr`, `alb`, `ecs-service`, `github-oidc`,
  `observability`) composed by thin per-environment root modules (`environments/dev`,
  `environments/prod`). Modules take explicit inputs/outputs — no hidden coupling.
- **Variables & outputs**: every module is parameterised (sizes, subnet CIDRs, log retention, image,
  environment name); each root module outputs what a human or CI pipeline actually needs next (ALB
  DNS name, ECR URL, deploy role ARN, dashboard name).
- **Sensible naming**: everything is prefixed `finzla-<environment>`, so resources are unambiguous
  in the AWS console and never collide between dev and prod.
- **Environment separation**: `dev` and `prod` are two independent root modules with two independent
  state files (`dev/terraform.tfstate`, `prod/terraform.tfstate` in the same versioned S3 bucket).
  Sizing differs deliberately — dev uses a single NAT gateway and one task (cost-optimised); prod
  uses one NAT per AZ and a minimum of two tasks (availability-optimised). A `terraform apply` in
  one environment's directory can only ever touch that environment's state and resources.
- **No hard-coded credentials**: the AWS provider takes no static keys — see OIDC below. The only
  "secret-shaped" value in the whole repo is a Secrets Manager placeholder, and Terraform is
  explicitly told to ignore its content after creation (`lifecycle { ignore_changes = [secret_string] }`)
  so real values are never written through `terraform apply`, plan output, or state diffs.
- **Minimal duplication**: `dev` and `prod` call the exact same modules with different variables;
  there's no copy-pasted resource logic between them.

### Managing AWS without `AdministratorAccess`

1. **Remote Terraform state** — a versioned, encrypted, private S3 bucket (`terraform/bootstrap`),
   created once by whoever bootstraps the account. Everyday Terraform runs (human or CI) only need
   `s3:GetObject`/`PutObject` on that one bucket's prefix and `s3:ListBucket` — not account-wide S3
   access, and never the bucket's own management (delete/versioning/policy changes stay with
   whoever ran bootstrap).
2. **State locking & concurrent changes** — the S3 backend's native locking (`use_lockfile = true`,
   Terraform ≥1.10) prevents two `terraform apply` runs against the same state from racing; the
   second one fails fast with "state is locked" instead of corrupting state. (`bootstrap/` also
   provisions a DynamoDB lock table as the traditional fallback, for teams pinned to older
   Terraform versions.)
3. **Dev and production environments** — separate state files today (this repo), which is enough to
   guarantee `terraform apply` in one environment cannot touch another's resources. The natural next
   step for a real fintech workload is **separate AWS accounts** per environment (via AWS
   Organizations), so a credential compromise or a Terraform mistake in dev has zero blast radius in
   prod — see "Production Readiness" below.

None of the above requires `AdministratorAccess` for routine work: a human operator or CI role needs
only the specific `ec2:*`, `ecs:*`, `elasticloadbalancing:*`, `logs:*`, `iam:*Role*` (scoped to the
`finzla-*` naming prefix) actions this Terraform actually calls, plus the narrow S3/DynamoDB access
above for state.

## 3. CI/CD and Deployment

Pipeline shape, exactly as required: **Pull Request -> Validation -> Review -> Merge -> Build ->
Push -> Deploy -> Health Check.**

- **Pull Request** ([`.github/workflows/pr.yml`](.github/workflows/pr.yml)): `terraform fmt -check`,
  `terraform validate`, and `terraform plan` (using a **read-only** AWS role — it cannot create,
  modify, or delete anything) for both dev and prod; the app's pytest suite; a Docker build; a
  **Trivy** scan of the built image for CRITICAL/HIGH CVEs (fails the check); and a **checkov** scan
  of the Terraform for misconfigurations.
- **Review**: enforced by GitHub branch protection on `main` (required PR review + required status
  checks before merge) — configured in repo settings, not in workflow YAML.
- **Merge -> Build -> Push -> Deploy -> Health Check**
  ([`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)): on push to `main`, the image is
  built once, then deployed to **dev** automatically, then to **prod**. Each environment job
  authenticates to AWS via OIDC using *that environment's own* deploy role, pushes the image to
  *that environment's own* ECR repo, renders a new ECS task definition, and calls
  `amazon-ecs-deploy-task-definition` with `wait-for-service-stability: true` — this is the pipeline's
  health check: it blocks until the new tasks are `RUNNING` **and** healthy in the ALB target group,
  and fails the job if they never become healthy.

**GitHub authenticates to AWS via OIDC** (`aws-actions/configure-aws-credentials` with
`role-to-assume`, no `aws-access-key-id` anywhere). There are no permanent AWS access keys stored in
GitHub — no secret to leak, rotate, or accidentally commit.

**Production has an approval gate**: `deploy-prod` runs under the GitHub `production` **Environment**,
which is configured with required reviewers in repo settings. The job (and the OIDC token it would
present) doesn't exist until that approval happens.

### What prevents another repo, a compromised workflow, or an individual developer from freely deploying to production?

Three independent layers, not one:

1. **No credentials to steal.** There are no static AWS keys in GitHub at all — nothing to exfiltrate
   from secrets, a compromised action, or a malicious dependency.
2. **The trust policy is scoped to one exact identity.** The prod deploy role's trust policy (see
   [`modules/github-oidc/main.tf`](terraform/modules/github-oidc/main.tf)) only accepts an OIDC token
   whose `sub` claim equals `repo:<org>/finzla-cloud-assessment:environment:production` — a specific
   repo *and* a specific GitHub Environment. A different repository, a fork, or a branch running
   outside that environment gets a token with a different `sub` and AWS's `sts:AssumeRoleWithWebIdentity`
   simply refuses it before any AWS action is attempted.
3. **The environment itself is gated.** GitHub only mints a token carrying `environment:production`
   for a job that has already been dispatched against that Environment — which happens only after
   its required reviewers approve. An individual developer's own AWS credentials are irrelevant here
   because developers are never issued standing AWS credentials at all; the only path to prod is
   through the pipeline, and the pipeline is gated as above.

### Handling an unhealthy deployment

`aws_ecs_service.deployment_circuit_breaker { enable = true, rollback = true }` (in
[`modules/ecs-service/main.tf`](terraform/modules/ecs-service/main.tf)) means ECS itself detects a
new task definition failing to reach a steady healthy state and automatically stops the rollout and
reverts to the last known-good task definition — no pipeline logic required. The pipeline's
`wait-for-service-stability: true` step surfaces this as a failed CI job (so the team is notified and
`main` is not silently broken), and its failure step prints the last 10 ECS service events for a fast
first look at *why* before anyone opens the AWS console.

## 4. Security & Operations

- **Least-privilege IAM**: three distinct roles, each scoped to what it actually does — see the deep
  dive below.
- **Restricted security groups**: only the ALB's security group accepts `0.0.0.0/0`, and only on
  80/443. The ECS tasks' security group accepts traffic *only* from the ALB's security group, on the
  container port. Nothing else in the VPC is reachable from the internet.
- **HTTPS/TLS**: the ALB listener on 443 uses `ELBSecurityPolicy-TLS13-1-2-2021-06`; port 80 redirects
  to 443 once a certificate is attached (`certificate_arn` variable — left unset here since this repo
  isn't tied to a real domain, called out explicitly rather than silently serving plaintext).
- **Encryption**: the Terraform state bucket uses SSE-KMS; the ECR repository uses KMS encryption for
  image layers; CloudWatch Logs are encrypted at rest by default.
- **Secure secrets management**: application secrets live in Secrets Manager and are injected at
  container launch via the ECS `secrets` mechanism (using the *execution* role's
  `secretsmanager:GetSecretValue`, scoped to that one secret's ARN) — never in the task definition's
  plaintext environment, never in source, never in Terraform state as a real value.
- **Secure GitHub-to-AWS auth**: OIDC federation, per-environment roles, no static keys (detailed
  above).
- **Separation between environments**: separate VPCs, separate ECS clusters/services, separate ECR
  repos, separate IAM roles, separate Terraform state, per environment.

### Most security-sensitive role: the production deploy role (`finzla-prod-deploy`)

1. **What it can do**: push images to the `finzla-prod` ECR repo; register new ECS task definition
   revisions; update the `finzla-prod` ECS service to run a new revision; pass exactly two specific
   IAM roles (the task's execution and task roles) to `ecs-tasks.amazonaws.com` only; read/write the
   `prod/` prefix of the Terraform state bucket. Nothing else — no `iam:CreateRole`, no
   `ec2:*`, no wildcard resources except where AWS's IAM model has no resource-level permissions to
   restrict (`ecr:GetAuthorizationToken`, `ecs:RegisterTaskDefinition`).
2. **Why those permissions are required**: this is the complete set of AWS calls a deploy actually
   makes — nothing here exists for convenience.
3. **What could happen if it were compromised**: an attacker with this role could ship an arbitrary
   container image to production and read the state file at that S3 prefix (which contains resource
   IDs and ARNs, not application secrets). They could **not** create IAM users/roles, open security
   groups, touch DNS, read the actual secret value in Secrets Manager, modify dev's or any other
   environment's resources, or grant themselves broader access — `iam:PassRole` is locked to exactly
   two role ARNs and conditioned on `iam:PassedToService = ecs-tasks.amazonaws.com`, so it cannot be
   used to escalate to a different, more powerful role.
4. **What limits its blast radius**: the trust policy means this role can only ever be assumed by a
   workflow run that already cleared the `production` GitHub Environment's approval gate, and even
   then only for a maximum 1-hour session (`max_session_duration = 3600`, AWS's minimum). It has no
   access to dev's VPC, ECR repo, cluster, or state prefix. Compare this to `AdministratorAccess`
   attached to a static, unrotated GitHub secret — the realistic alternative many teams reach for —
   where a single leaked key is a full account compromise.

## 5. Monitoring

**Implemented metrics/alarms** ([`modules/observability`](terraform/modules/observability/main.tf)):
a CloudWatch dashboard tracking request latency (p50/p99), ECS CPU & memory utilisation, running task
count, 5xx count and unhealthy-host count — and two of those are wired to alarms:

| Alert | Trigger | Why it matters | Who receives it | First investigation step |
|---|---|---|---|---|
| **HTTP 5xx rate** | >10 target 5xx responses/min for 5 consecutive minutes | Usually an application-level failure (bug, bad config in a new release, a downstream dependency down) rather than an infra problem | On-call engineer (SNS -> email/Slack/PagerDuty) | Check the ECS task logs in CloudWatch for the same time window for stack traces |
| **Unhealthy targets** | ≥1 target failing ALB health checks for 3 consecutive minutes | Users may be losing capacity or all traffic, depending on how many targets are affected | On-call engineer | `aws ecs describe-services` for recent events, then check the task's `/health` endpoint directly and its logs for a crash loop |

Application logs land in CloudWatch Logs, log group `/ecs/finzla-<environment>` (one stream per task,
`awslogs-stream-prefix = app`), retained **14 days in dev, 90 days in prod** — long enough to
investigate an incident days later without keeping indefinite, ever-growing (and ever-costing) log
volume for a fintech workload's non-regulated application logs. (Any log stream that *is* subject to
a specific regulatory retention requirement — e.g. audit trails — should get its own log group with a
policy-driven retention, which is a production-readiness item below, not something this generic
service log group should silently take on.)

## 6. Incident Investigation

**Scenario**: GitHub Actions says "Deployment successful," ECS says "Expected tasks running," but
customers get HTTP 503 and the ALB reports unhealthy targets.

1. **What I'd investigate first**: the ALB target group's health check status and reason
   (`aws elbv2 describe-target-health`) — it tells you immediately *why* a target is marked unhealthy
   (timeout, connection refused, wrong HTTP code), which narrows the next step before touching
   anything else.
2. **Services/logs/metrics to inspect**: ALB target health reasons; the CloudWatch dashboard's
   5xx/unhealthy-host graphs for exact timing versus the deploy; the ECS task's CloudWatch logs
   (`/ecs/finzla-<env>`) for crash/exception output around the deploy time; `aws ecs describe-tasks`
   for the running tasks' health status and any `stoppedReason` on tasks that exited; the ECS
   service's event list for scheduler-level messages.
3. **At least three possible causes**:
   - The container is running but not actually listening on the port the target group checks (e.g. a
     config/env mismatch changed the bind port, or `APP_ENV` selected a code path that fails to start
     the HTTP server).
   - The app starts but `/health` itself fails (a dependency check inside `/health` — DB, downstream
     API — that isn't actually reachable from this environment/security group).
   - A security group or NACL change (possibly bundled in the same deploy/PR) now blocks the ALB's
     health-check traffic from reaching the task port, even though "expected tasks running" is true
     at the ECS scheduler level (ECS only knows the task process is alive, not that the network path
     to it is open).
4. **Prove or eliminate each**: (a) check the target group's health-check port/path config against
   what the container actually exposes, and `docker exec`/logs to confirm what port it's bound to;
   (b) hit `/health` directly from inside the VPC (e.g. from a bastion or another task in the same
   subnet) to see if it's the app or the network path that's failing; (c) diff the task security
   group rules against the last known-good Terraform state/plan for that PR — a security-group change
   is often the one thing "the app looks fine" doesn't rule out.
5. **Safest immediate recovery action**: roll the ECS service back to the previous, known-good task
   definition revision (`aws ecs update-service --task-definition finzla-<env>:<previous-revision>`).
   This is safe because it's the exact configuration that was healthy minutes ago — it doesn't
   require diagnosing the root cause first, and it stops customer impact immediately. (In the common
   case this already happened automatically via `deployment_circuit_breaker`; this step is for the
   case where the *new* tasks technically reached "running" — so the circuit breaker didn't trip —
   but still failed the ALB's independent health check, e.g. cause #3 above.)
6. **Preventing recurrence**: add a **post-deploy smoke test** to the pipeline that calls `/health`
   through the *actual ALB DNS name* (not just "ECS says tasks are running") before considering a
   deploy successful — this specific failure mode is exactly the gap between "ECS-level running" and
   "ALB-level reachable" that a scheduler-only health check misses. Also: treat any PR touching
   security groups as higher-risk in review, since that's the class of change most likely to produce
   this exact symptom.

## 7. Engineering Judgement

**Architecture** — covered above: ECS/Fargate chosen for operational simplicity at this scale; EKS
rejected as unnecessary complexity for one stateless service.

**Reliability** — a deployment that fails its health checks is caught by
`deployment_circuit_breaker` and automatically rolled back to the previous task definition; see
"Handling an unhealthy deployment" above. Manual rollback, if ever needed:
`aws ecs update-service --cluster finzla-<env>-cluster --service finzla-<env> --task-definition finzla-<env>:<N>`
for a specific previous revision, or re-run `deploy.yml` from a previous commit on `main`.

**Cost** — the two largest likely drivers here are **NAT Gateway** (hourly charge *plus*
per-GB data processing — prod runs two for AZ redundancy) and **Fargate vCPU/memory** (billed per
second while tasks run; prod's `desired_count = 2` doubles that baseline versus dev's single task).
Controlling them: right-size `cpu`/`memory` against actual utilisation (the dashboard's CPU/memory
widgets exist precisely to inform this) rather than guessing; consider VPC endpoints for ECR/S3/Logs
if NAT data-processing cost becomes material, since that traffic then bypasses the NAT gateway
entirely; and let dev intentionally run leaner (single NAT, single task) since it doesn't need prod's
availability guarantees.

**Production readiness** — the three most important improvements before calling this
production-ready for a fintech platform:

1. **Separate AWS accounts per environment** (via AWS Organizations), not just separate state files
   in one account — the strongest blast-radius boundary available, and standard practice for
   regulated workloads.
2. **A real TLS certificate and domain** via ACM + Route 53, and WAF in front of the ALB for
   basic layer-7 protection (rate limiting, common exploit signatures) — neither is wired up here
   since this repo isn't tied to a real domain.
3. **A structured, tested incident response path**: the alarms here notify a topic, but a fintech
   platform needs that wired into an actual on-call/paging tool with defined escalation, plus the
   post-deploy smoke test from the Incident Investigation section closing the specific gap this
   assessment's scenario surfaces.

## Evidence this works

Run from a clean checkout:

```bash
# Terraform — formatting, structural validation (no AWS credentials needed)
cd terraform/bootstrap && terraform init -backend=false && terraform validate
cd ../environments/dev && terraform init -backend=false && terraform validate
cd ../prod && terraform init -backend=false && terraform validate
cd ../../.. && terraform fmt -check -recursive terraform

# Application — unit tests
pip install -r app/requirements-dev.txt
cd app && python -m pytest -v

# Container — build, run, and hit both endpoints
docker build -t finzla-assessment:local .
docker run -d --name finzla-test -p 8000:8000 -e APP_ENV=local finzla-assessment:local
curl localhost:8000/health   # {"status":"ok",...}
curl localhost:8000/version  # {"version":"0.0.0","git_commit":"unknown",...}
docker inspect --format='{{.State.Health.Status}}' finzla-test   # healthy
```

All of the above was run locally while building this repo (Terraform 1.14.8, Docker 29.1.3, Python
3.14): `terraform fmt`/`validate` passed clean for `bootstrap`, `dev`, and `prod`; the Docker image
built and ran with `/health` and `/version` returning `200`, logs visible via `docker logs`, and the
container's own `HEALTHCHECK` reporting `healthy`; `pytest` passed 2/2. No live AWS deployment was
performed (no AWS account was provisioned for this exercise) — the Terraform and GitHub Actions
configuration is complete enough for another engineer to run `terraform apply` and merge to `main`
and have it deploy, per the assessment's own allowance for this.

## Deploying this for real

1. `cd terraform/bootstrap && terraform init && terraform apply` (needs one-time elevated
   privileges to create the state bucket, lock table, and GitHub OIDC provider).
2. Update `github_org`/`github_repo` in `terraform/environments/{dev,prod}/terraform.tfvars`.
3. `cd terraform/environments/dev && terraform init && terraform apply`, then the same for `prod`.
4. In the GitHub repo: create `development` and `production` Environments (Settings -> Environments);
   add required reviewers to `production`; set each Environment's `AWS_DEPLOY_ROLE_ARN` variable to
   that environment's `github_actions_deploy_role_arn` Terraform output. Optionally set a repo-level
   `AWS_PLAN_ROLE_ARN` variable (a separate, read-only role) to enable `terraform plan` on PRs.
5. Open a PR, merge it, watch `deploy.yml` build, push, deploy to dev, then wait for prod approval.

## Submission checklist

- [x] Application source code — `app/`
- [x] Dockerfile — `Dockerfile`
- [x] Terraform — `terraform/`
- [x] GitHub Actions workflow — `.github/workflows/`
- [x] README — this file
- [x] Simple architecture diagram — `docs/architecture.md`
- [x] No AWS credentials, passwords, tokens, keys, or other secrets committed
