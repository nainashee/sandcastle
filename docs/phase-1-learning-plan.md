# SandCastle Phase 1 — Day-by-Day Learning Plan

> Phase 1 goal: Build the foundation. By the end of Day 7 you have a working EC2 dev box on AWS, accessible via SSM, with your full toolchain installed and your first project (CloudHunt) migrated onto it.

## How to Use This Plan

- **Pace yourself**: One day = one session = ~60-90 minutes. Don't rush. The "why" matters more than the "what."
- **Read first, then do**: Each day starts with a "Why we're doing this" section. Read it fully before touching a terminal.
- **Type, don't paste**: When you're learning, typing commands by hand burns them into muscle memory. Copy-paste is fine after you've done a command twice.
- **End-of-day discipline**: Always finish the day's reflection, quiz, and interview questions. This is where the learning compounds. **Skipping these is the difference between "I built a thing" and "I understand a thing."**
- **Stuck for more than 30 minutes?** Stop. Document what you tried in LEARNINGS.md. Move on or ask for help. Getting stuck and not noticing it is the biggest time sink in self-directed learning.

## Phase 1 Overview

> **Prerequisite**: Day 0 (IAM Identity Center setup) must be complete before starting Day 1. Day 0 lives in its own doc and establishes the access foundation every command below depends on. See `docs/aws-access.md` for the access model.

| Day | Topic | Deliverable |
|-----|-------|-------------|
| 1 | Repo scaffolding + Terraform state backend | `nainashee/sandcastle` repo + S3 state bucket + DynamoDB lock table |
| 2 | Terraform basics + VPC and networking | `terraform/modules/networking/` working |
| 3 | IAM roles, policies, and instance profiles | `terraform/modules/iam/` working |
| 4 | EC2 instance with SSM | Instance running, SSM session works |
| 5 | User data and toolchain bootstrap | Instance has full dev toolchain on first boot |
| 6 | First connection + project migration | CloudHunt running from SandCastle |
| 7 | Polish, tags, outputs, and commit | Phase 1 fully shipped, GitHub repo public-ready |

---

# Day 1 — Repo Scaffolding and Terraform State Backend

**Time estimate**: 75 minutes
**Prerequisites**: Day 0 (IAM Identity Center setup) complete — `sandcastle` SSO profile working, MFA enforced, `docs/aws-access.md` written. Git installed, GitHub account (`nainashee`).

> **SSO reminder**: All AWS commands in this plan use the `sandcastle` profile. If you get `ExpiredToken` or `Unable to locate credentials`, your SSO session has expired. Run:
> ```bash
> aws sso login --sso-session nainashee
> ```
> Sessions last ~8 hours. One login refreshes all four profiles (`sandcastle`, `cloudhunt`, `launchpad-sso`, `playhowzat`).

## Why we're doing this today

Every serious Terraform project has a problem called "the chicken and the egg." Terraform stores its state (a JSON file that tracks what it has created) in a backend — usually an S3 bucket with a DynamoDB lock table. But that S3 bucket and DynamoDB table need to exist *before* Terraform can use them. So you can't create them with the same Terraform that depends on them.

The solution is a one-time bootstrap: create the state backend manually (via a shell script with AWS CLI commands), then everything else gets managed by Terraform. You only do this once per project.

This is also why your CloudHunt project has a bucket called `jobhunt-terraform-state-989126024881` — that bucket was created outside of Terraform first, so Terraform could use it for everything else.

Today you're building the bootstrap script and the empty repo skeleton. You're learning:

- **Why state matters**: Without state, Terraform doesn't know what already exists in AWS. Lose your state, and Terraform thinks nothing exists and tries to recreate everything (disaster).
- **Why remote state matters**: If state lives only on your laptop, no one else (including future-you on a different machine) can manage the infrastructure. Remote state in S3 solves that.
- **Why locking matters**: If two `terraform apply` commands run at the same time on the same state, you corrupt the state file. DynamoDB locks prevent this.

## Step 1: Create the GitHub repository (5 min)

Go to github.com → New Repository:

- Name: `sandcastle`
- Visibility: Public (it's a portfolio piece)
- Don't initialize with README/license/gitignore (we'll add our own)

Then locally:

```bash
mkdir -p ~/dev/sandcastle
cd ~/dev/sandcastle
git init
git branch -M main
git remote add origin git@github.com:nainashee/sandcastle.git
```

**Why public?** Portfolio projects need to be visible. Private repos are invisible to recruiters and interviewers. There's nothing sensitive in SandCastle — no real secrets, no proprietary code — so public is the right choice.

> **Carry-over from Day 0**: You already wrote `docs/aws-access.md` during Day 0 Step 9 and saved it somewhere local. Copy it into the new repo's `docs/` folder now (you'll create the folder in Step 2):
> ```bash
> mkdir -p docs && cp /path/to/saved/aws-access.md docs/
> ```
>
> **Legacy IAM user burn-in (FYI)**: Day 0 deactivated three IAM users (`launchpad-dev`, `cricket-zone-dev`, `hussain-admin`) with a delete date of **2026-06-09**. If any command in this plan still says `--profile launchpad` it's an oversight — flag it. The current correct profile names are `sandcastle`, `cloudhunt`, `launchpad-sso`, `playhowzat`. Any code on your laptop that still uses the old `launchpad` profile name will break on 2026-06-09 when the underlying IAM user is deleted — though since those keys are already `Inactive`, it's already broken; you just haven't run it yet.

## Step 2: Create the directory structure (5 min)

```bash
mkdir -p bootstrap docs scripts terraform/modules/{networking,iam,compute,automation,observability} lambda/auto_stop
```

**Why this structure?** Modular Terraform is how real teams organize IaC. Flat directories with 20 `.tf` files don't scale. Separating by responsibility (networking, IAM, compute) means changes are localized and modules can theoretically be reused.

## Step 3: Add a .gitignore (5 min)

Create `.gitignore`:

```gitignore
# Terraform
**/.terraform/*
*.tfstate
*.tfstate.*
*.tfvars
*.tfvars.json
crash.log
crash.*.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json
.terraformrc
terraform.rc
.terraform.lock.hcl.bak

# OS
.DS_Store
Thumbs.db

# Editors
.vscode/
.idea/
*.swp
*.swo

# Lambda build artifacts
lambda/**/build/
lambda/**/*.zip

# Local environment
.env
.env.local
```

**Why each block?**

- `**/.terraform/*` — Terraform downloads provider plugins here. Hundreds of MB. Never commit them.
- `*.tfstate` — State files contain real infrastructure data and sometimes secrets. Never commit. (Even though state is remote, sometimes a stray local state file appears.)
- `*.tfvars` — Variable files often contain account-specific values. Commit `terraform.tfvars.example` instead.
- Editor and OS junk — keeps the repo clean for collaborators (including future you).

## Step 4: Write the state backend bootstrap script (30 min)

Create `bootstrap/bootstrap-state-backend.sh`:

```bash
#!/usr/bin/env bash
#
# bootstrap-state-backend.sh
# One-time setup of the Terraform state backend for SandCastle.
# Creates an S3 bucket (versioned, encrypted) and a DynamoDB lock table.
#
# Run this ONCE, before the first `terraform init`.
# Idempotent: safe to run multiple times.

set -euo pipefail

# ---- Configuration ----
AWS_REGION="us-east-1"
PROJECT_NAME="sandcastle"

# Day 0 discipline: profile must be set explicitly. No defaults.
if [ -z "${AWS_PROFILE:-}" ]; then
  echo "ERROR: AWS_PROFILE must be set explicitly."
  echo "Example: AWS_PROFILE=sandcastle ./bootstrap-state-backend.sh"
  echo ""
  echo "If you get a credential error after setting it, run:"
  echo "  aws sso login --sso-session nainashee"
  exit 1
fi

# Account ID is appended for global S3 bucket uniqueness
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --profile "$AWS_PROFILE")
BUCKET_NAME="${PROJECT_NAME}-terraform-state-${ACCOUNT_ID}"
LOCK_TABLE_NAME="${PROJECT_NAME}-terraform-lock"

echo "==> SandCastle state backend bootstrap"
echo "    Region:     $AWS_REGION"
echo "    Profile:    $AWS_PROFILE"
echo "    Account:    $ACCOUNT_ID"
echo "    Bucket:     $BUCKET_NAME"
echo "    Lock table: $LOCK_TABLE_NAME"
echo ""

# ---- S3 Bucket ----
echo "==> Creating S3 bucket for Terraform state..."
if aws s3api head-bucket --bucket "$BUCKET_NAME" --profile "$AWS_PROFILE" 2>/dev/null; then
  echo "    Bucket already exists. Skipping creation."
else
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE"
  echo "    Created bucket: $BUCKET_NAME"
fi

# Versioning: lets you roll back if state is corrupted
echo "==> Enabling versioning on bucket..."
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled \
  --profile "$AWS_PROFILE"

# Encryption: state files can contain sensitive resource data
echo "==> Enabling default encryption (AES256)..."
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }' \
  --profile "$AWS_PROFILE"

# Block public access: state should NEVER be public
echo "==> Blocking all public access..."
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
  --profile "$AWS_PROFILE"

# Tagging: for cost allocation
echo "==> Tagging bucket..."
aws s3api put-bucket-tagging \
  --bucket "$BUCKET_NAME" \
  --tagging 'TagSet=[
    {Key=Project,Value=sandcastle},
    {Key=Owner,Value=hussain},
    {Key=ManagedBy,Value=bootstrap-script}
  ]' \
  --profile "$AWS_PROFILE"

# ---- DynamoDB Lock Table ----
echo "==> Creating DynamoDB lock table..."
if aws dynamodb describe-table --table-name "$LOCK_TABLE_NAME" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null; then
  echo "    Lock table already exists. Skipping creation."
else
  aws dynamodb create-table \
    --table-name "$LOCK_TABLE_NAME" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags \
      Key=Project,Value=sandcastle \
      Key=Owner,Value=hussain \
      Key=ManagedBy,Value=bootstrap-script \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE"

  echo "==> Waiting for lock table to become active..."
  aws dynamodb wait table-exists \
    --table-name "$LOCK_TABLE_NAME" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE"
  echo "    Lock table is active."
fi

echo ""
echo "==> Done. Add this to terraform/backend.tf:"
echo ""
echo 'terraform {'
echo '  backend "s3" {'
echo "    bucket         = \"$BUCKET_NAME\""
echo '    key            = "phase-1/terraform.tfstate"'
echo "    region         = \"$AWS_REGION\""
echo "    dynamodb_table = \"$LOCK_TABLE_NAME\""
echo '    encrypt        = true'
echo '  }'
echo '}'
```

Make it executable:

```bash
chmod +x bootstrap/bootstrap-state-backend.sh
```

**Why each AWS feature?**

- **Versioning**: If state gets corrupted (it happens), you can roll back to a previous version. This is your insurance policy.
- **Encryption**: State files contain ARNs, resource IDs, and sometimes embedded secrets. Encryption is a default control with zero cost.
- **Block public access**: A public state bucket is a catastrophic leak. This is belt-and-suspenders — even if a future policy is misconfigured, this account-level block stays in effect.
- **PAY_PER_REQUEST DynamoDB billing**: For locks (a handful of writes per day), pay-per-request is cheaper than provisioned capacity. You don't need capacity planning for a lock table.

## Step 5: Run the bootstrap (5 min)

```bash
./bootstrap/bootstrap-state-backend.sh
```

Expected output ends with the `backend "s3"` block that you'll use tomorrow.

## Step 6: Verify in AWS Console (5 min)

- Go to S3 console → confirm `sandcastle-terraform-state-989126024881` exists with versioning enabled
- Go to DynamoDB console → confirm `sandcastle-terraform-lock` is in "Active" state

**Why verify visually?** Because automation can silently fail in subtle ways. Eyeballing the actual resources catches things the script's exit code missed.

## Step 7: First commit (5 min)

```bash
git add .
git commit -m "Day 1: Repo skeleton and state backend bootstrap"
git push -u origin main
```

## What You Built Today

A reproducible Terraform state backend (S3 + DynamoDB) created via a single shell script, plus the repo scaffolding for everything else.

## End-of-Day Reflection

Add to `LEARNINGS.md`:

```markdown
## YYYY-MM-DD — Day 1: State backend bootstrap

**What I built**: S3 state bucket with versioning + encryption, DynamoDB lock table, repo scaffolding.

**What I learned**: [your words]

**What surprised me**: [your words]

**Stuck moments**: [your words, even if "none"]
```

## Multiple Choice Quiz

**Q1.** Why does the Terraform state backend (S3 + DynamoDB) need to be created *outside* of Terraform?
- A) AWS rate-limits backend resource creation when done via Terraform
- B) The S3 bucket can technically be created by Terraform, but the DynamoDB lock table cannot
- C) The state backend must exist before `terraform init` can use it; you can't store state in a bucket Terraform hasn't created yet
- D) Terraform doesn't support S3 buckets in its AWS provider

**Q2.** Two engineers run `terraform apply` against the same state file at the same time, without a lock table configured. What's the most likely outcome?
- A) State corruption: one apply overwrites the other's state, leaving Terraform's view out of sync with AWS reality
- B) The second `apply` queues automatically and runs after the first finishes
- C) Both applies succeed cleanly because S3 versioning resolves the conflict
- D) AWS API rate limiting prevents one of them from completing

**Q3.** You discover your `terraform.tfstate` file in S3 has been silently corrupted. Versioning is enabled. What's your fastest recovery path?
- A) Run `terraform refresh` to rebuild state from current AWS resources
- B) Delete the state and run `terraform import` for every resource
- C) Use AWS Config to roll back the affected resources
- D) Use S3 versioning to restore a known-good prior version of the state object

**Q4.** Of the four S3 Block Public Access settings (`BlockPublicAcls`, `IgnorePublicAcls`, `BlockPublicPolicy`, `RestrictPublicBuckets`), which is most directly defending against a future colleague accidentally attaching a permissive bucket policy?
- A) `BlockPublicAcls`
- B) `BlockPublicPolicy`
- C) `IgnorePublicAcls`
- D) `RestrictPublicBuckets`

**Q5.** You're choosing between `PAY_PER_REQUEST` and `PROVISIONED` (with 5 RCU/5 WCU) billing for the Terraform lock table. The lock table sees roughly 20 read/write operations per day. Why is `PAY_PER_REQUEST` the right call?
- A) `PAY_PER_REQUEST` has no minimum monthly cost and scales to zero between applies; provisioned would bill 24/7 for capacity you barely use
- B) Provisioned capacity has a 25 RCU/WCU minimum which would be wasteful for this workload
- C) Lock operations require the higher consistency model only `PAY_PER_REQUEST` provides
- D) `PROVISIONED` doesn't support the `LockID` partition key Terraform requires

<details>
<summary>Answers</summary>

1. **C** — The chicken-and-egg framing. Note A (rate limiting), B (DynamoDB-can't-be-Terraformed), and D (no S3 support) are all plausible-sounding wrong answers — Terraform can absolutely create both S3 buckets and DynamoDB tables, the issue is purely about ordering.

2. **A** — State corruption is the real risk. Note B is wrong but tempting: Terraform doesn't queue applies, that's what the DynamoDB lock is supposed to do (and is absent in this scenario). C confuses object versioning with concurrency control.

3. **D** — S3 versioning is exactly why we enabled it on Day 1. Note A (`terraform refresh`) sounds plausible but refresh updates state from reality — it can't undo a corruption that already wrote bad state. B works but is hours of work; D is seconds.

4. **B** — `BlockPublicPolicy` specifically prevents new public bucket policies from being attached. `BlockPublicAcls` (A) deals with ACLs, not policies. `IgnorePublicAcls` (C) ignores existing public ACLs. `RestrictPublicBuckets` (D) prevents public access at the request level. All four together form defense-in-depth — the question asks which one targets the specific scenario.

5. **A** — Cost behavior. Note B is wrong on the specifics (provisioned has no 25 RCU minimum — you can provision as low as 1). C and D invent technical requirements that don't exist. The real reason is purely economic: sporadic workloads + always-on provisioning = waste.

</details>

## Interview Questions

These are the kinds of questions a cloud engineer interviewer would ask about today's work. Practice answering them out loud, in 1-2 minutes each.

1. **"Walk me through how you'd set up Terraform state for a new project."**
   *Hint: Mention the chicken-and-egg problem, S3 + DynamoDB pattern, versioning, encryption, and why a bootstrap script is the standard approach.*

2. **"Why use S3 for Terraform state instead of just keeping it local?"**
   *Hint: Collaboration, durability, accessibility from any machine, encryption at rest, versioning.*

3. **"What happens if two engineers run `terraform apply` at the same time without state locking?"**
   *Hint: Race condition, state corruption, drift between Terraform's view and reality, possibly orphaned resources.*

4. **"How would you recover from a corrupted Terraform state file?"**
   *Hint: S3 versioning allows restoring a previous version. Worst case, `terraform import` to rebuild state from existing resources.*

5. **"Why is `BlockPublicAcls=true, IgnorePublicAcls=true, BlockPublicPolicy=true, RestrictPublicBuckets=true` important for a state bucket?"**
   *Hint: Defense in depth. Even if a future bucket policy accidentally grants public access, the account-level block prevents the data from being exposed.*

---

# Day 2 — Terraform Basics and VPC Networking

**Time estimate**: 90 minutes
**Prerequisites**: Day 1 complete

## Why we're doing this today

Today you write your first Terraform code for SandCastle. You're building the networking module: VPC, subnet, internet gateway, route tables, security group.

Networking is always the first layer in a cloud project because everything else (compute, databases, Lambda) lives inside a network. Get the network wrong and you'll fight it for the rest of the project.

You're learning:

- **Terraform basics**: providers, resources, variables, outputs, modules
- **VPC fundamentals**: CIDR blocks, subnets, route tables, gateways
- **The "public subnet with no inbound" pattern**: why this beats "private subnet + NAT Gateway" for personal dev environments

## Step 1: Create the provider configuration (10 min)

Create `terraform/providers.tf`:

```hcl
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "sandcastle"
      Owner     = "hussain"
      ManagedBy = "terraform"
    }
  }
}
```

**Why each piece?**

- `required_version`: Pins Terraform CLI to >= 1.6. Prevents subtle bugs from old versions.
- `required_providers`: Pins the AWS provider to the 5.x major version. New major versions can have breaking changes; this prevents accidental upgrades.
- `default_tags`: Every resource created by this provider gets these tags automatically. This is huge — you can't forget to tag a resource. Cost Explorer and IAM policies depend on consistent tagging.

## Step 2: Create the backend config (5 min)

Create `terraform/backend.tf` using the output from yesterday's bootstrap script:

```hcl
terraform {
  backend "s3" {
    bucket         = "sandcastle-terraform-state-989126024881"
    key            = "phase-1/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "sandcastle-terraform-lock"
    encrypt        = true
  }
}
```

## Step 3: Define variables and outputs (10 min)

Create `terraform/variables.tf`:

```hcl
variable "aws_region" {
  description = "AWS region to deploy SandCastle into"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use (Day 0 Identity Center SSO profile)"
  type        = string
  default     = "sandcastle"
}

variable "vpc_cidr" {
  description = "CIDR block for the SandCastle VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.20.1.0/24"
}

variable "availability_zone" {
  description = "AZ to deploy the subnet into"
  type        = string
  default     = "us-east-1a"
}
```

Create `terraform/outputs.tf` (empty for now; we'll add to it later):

```hcl
# Outputs are populated as modules are added
```

**Why variables for everything?** Hardcoded values are fine until they're not. The day you want to spin up a second SandCastle in `us-west-2` or change the CIDR to avoid conflicting with your home network, you'll be glad these are variables.

## Step 4: Build the networking module (40 min)

Create `terraform/modules/networking/main.tf`:

```hcl
# ---- VPC ----
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "sandcastle-vpc"
  }
}

# ---- Internet Gateway ----
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "sandcastle-igw"
  }
}

# ---- Public Subnet ----
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "sandcastle-public-1a"
    Tier = "public"
  }
}

# ---- Route Table ----
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "sandcastle-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---- Security Group ----
# Zero ingress rules: the keep is reachable only via SSM (outbound-initiated)
resource "aws_security_group" "keep" {
  name        = "sandcastle-keep-sg"
  description = "Security group for the SandCastle keep. No ingress."
  vpc_id      = aws_vpc.this.id

  # NOTE: no `ingress` blocks — that's the point.

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sandcastle-keep-sg"
  }
}
```

Create `terraform/modules/networking/variables.tf`:

```hcl
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
}

variable "availability_zone" {
  description = "AZ for the subnet"
  type        = string
}
```

Create `terraform/modules/networking/outputs.tf`:

```hcl
output "vpc_id" {
  description = "ID of the SandCastle VPC"
  value       = aws_vpc.this.id
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = aws_subnet.public.id
}

output "keep_security_group_id" {
  description = "ID of the security group for the keep"
  value       = aws_security_group.keep.id
}
```

## Step 5: Wire the module into the root config (5 min)

Create `terraform/main.tf`:

```hcl
module "networking" {
  source = "./modules/networking"

  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr
  availability_zone  = var.availability_zone
}
```

Update `terraform/outputs.tf`:

```hcl
output "vpc_id" {
  value = module.networking.vpc_id
}

output "public_subnet_id" {
  value = module.networking.public_subnet_id
}

output "keep_security_group_id" {
  value = module.networking.keep_security_group_id
}
```

## Step 6: Initialize, plan, apply (15 min)

```bash
cd terraform
terraform init
terraform fmt -recursive
terraform validate
terraform plan
```

**Read the plan carefully.** Don't just look for "no errors." Look for:

- The exact resources being created
- Any unexpected destroys (there shouldn't be any on first apply)
- Tag propagation (every resource should have `Project=sandcastle`)

If the plan looks right:

```bash
terraform apply
# Type 'yes' when prompted
```

Should take about 30 seconds.

## Step 7: Verify in AWS Console (5 min)

VPC console → confirm:
- `sandcastle-vpc` exists with CIDR `10.20.0.0/16`
- `sandcastle-public-1a` subnet exists
- `sandcastle-igw` is attached
- Route table has `0.0.0.0/0` → IGW
- Security group `sandcastle-keep-sg` exists with zero inbound rules

## Step 8: Commit (2 min)

```bash
cd ..
git add .
git commit -m "Day 2: Networking module - VPC, subnet, IGW, route table, SG"
git push
```

## What You Built Today

A working VPC with public subnet, internet gateway, route table, and the deliberately-zero-ingress security group for the keep.

## End-of-Day Reflection

Add to `LEARNINGS.md`:
```markdown
## YYYY-MM-DD — Day 2: Networking module

**What I built**: VPC, public subnet, IGW, route table, security group.

**What I learned**: [your words]

**What surprised me**: [your words]

**Stuck moments**: [your words]
```

## Multiple Choice Quiz

**Q1.** A colleague reviewing your Terraform asks why `sandcastle-keep-sg` has zero inbound rules but you can still get a shell on the instance. What's the technically correct explanation?
- A) The keep is in a public subnet, and public-subnet instances accept SSM traffic regardless of security group
- B) SSM Session Manager opens a port dynamically when a session starts
- C) The SSM agent on the instance maintains an outbound HTTPS connection to the SSM regional endpoint; the AWS Console proxies your shell through that pre-existing connection
- D) Security groups only filter inbound traffic from outside the VPC, and SSM traffic originates from within AWS

**Q2.** What does `map_public_ip_on_launch = true` on a subnet actually do?
- A) It allocates an Elastic IP for the subnet itself
- B) It maps the subnet's CIDR block to a public DNS zone
- C) It enables internet routing for the subnet
- D) It assigns a public IPv4 address to every instance launched in this subnet (without requiring an Elastic IP)

**Q3.** Your VPC has a public subnet, an Internet Gateway, and `enable_dns_hostnames = true`. You launch an instance, but it can't reach `pypi.org` to install Python packages. The most likely missing piece is:
- A) A NAT Gateway in the public subnet
- B) A `0.0.0.0/0` route to the IGW in the subnet's route table
- C) An outbound rule on the security group (egress is denied by default)
- D) A DNS resolver attached to the VPC

**Q4.** You add `default_tags { Project = "sandcastle" }` to the AWS provider, then run `terraform apply`. Which resources in your config receive the tag?
- A) Every resource created or updated by this provider, automatically — including future resources you haven't written yet
- B) Only resources explicitly listed in a `tags` argument
- C) Only top-level resources, not those inside modules
- D) Only resources created in the current `apply`; existing ones must be re-tagged manually

**Q5.** You set `enable_dns_hostnames = false` on the VPC. Which of these breaks?
- A) Outbound internet access from instances
- B) `terraform apply` will refuse to create the VPC
- C) SSM agent registration, because the agent resolves the SSM endpoint by hostname inside the VPC
- D) Security group rule evaluation for traffic identified by DNS name

<details>
<summary>Answers</summary>

1. **C** — The outbound-connection rendezvous model. Note D is plausible-sounding but wrong: security groups absolutely filter inbound traffic from inside the VPC too. A misframes how SSM works (subnet visibility is irrelevant). B is wrong — SSM doesn't open any ports.

2. **D** — Auto-assigns public IPs to launched instances. Note A confuses Elastic IPs with auto-assigned public IPs. B and C invent behaviors that don't exist.

3. **B** — The IGW route is the missing piece. Note A (NAT Gateway) is the *private subnet* solution — you already have an IGW for outbound, you just need the route. C is wrong because security groups *allow* all egress by default; the standard egress rule we wrote is redundant with the default. D is invented.

4. **A** — Provider-level default_tags apply to every resource the provider creates, including those inside modules and resources added later. Note D is a common misconception — provider-level changes do affect existing resources on the next apply.

5. **C** — SSM agent registration fails without DNS hostnames because the agent uses hostname-based service endpoints inside the VPC. Note A is wrong — DNS resolution and outbound internet are separate concerns. B is wrong — Terraform happily creates broken VPCs. D is invented (SGs work on IPs, not hostnames).

</details>

## Interview Questions

1. **"Walk me through the components of a VPC and what each does."**
   *Hint: CIDR block, subnets (public/private), route tables, internet gateway, NAT gateway, security groups, NACLs.*

2. **"What's the difference between a security group and a NACL?"**
   *Hint: SG = stateful, per-ENI, allow rules only. NACL = stateless, per-subnet, allow + deny rules. SGs are the day-to-day tool; NACLs are for coarse blocks.*

3. **"Why might you choose a public subnet over a private subnet with NAT Gateway for a dev environment?"**
   *Hint: Cost (NAT GW is $33/mo). For a personal dev box with no ingress, the security risk is equivalent.*

4. **"How does an internet gateway differ from a NAT gateway?"**
   *Hint: IGW = bidirectional, for resources with public IPs. NAT GW = outbound-only, for resources in private subnets.*

5. **"What is CIDR notation and why do we use /16 for the VPC and /24 for the subnet?"**
   *Hint: CIDR = Classless Inter-Domain Routing. /16 gives 65k addresses for the whole VPC; /24 gives 256 per subnet. Lets you carve the VPC into many subnets.*

---

# Day 3 — IAM Instance Profile and Role Assumption

**Time estimate**: 75 minutes
**Prerequisites**: Day 2 complete

## Why we're doing this today

Today you build the IAM layer — arguably the most important security boundary in AWS. IAM is what stops "I have a shell on a box" from becoming "I have your entire AWS account."

The pattern you're building is the modern best practice for EC2 access: **the instance has zero static credentials on disk; instead, an IAM instance profile provides temporary credentials via the metadata service**. When you need to do work for a specific project (CloudHunt), the instance assumes a project-specific role with scoped permissions.

You're learning:

- **The difference between IAM roles, policies, and instance profiles**
- **The principle of least privilege**
- **Why "AssumeRole" is the right pattern for cross-project access**
- **AWS managed policies vs custom policies**

## Step 1: Understand what you're building (10 min — read, don't code)

The IAM structure for SandCastle:

```
                  ┌────────────────────────────────┐
                  │  EC2 Instance (the keep)       │
                  │                                │
                  │  has attached:                 │
                  │  ┌─────────────────────────┐   │
                  │  │ Instance Profile         │   │
                  │  │ sandcastle-keep-profile  │   │
                  │  └────────────┬─────────────┘   │
                  │               │ wraps           │
                  │  ┌────────────▼─────────────┐   │
                  │  │ IAM Role                 │   │
                  │  │ sandcastle-keep-role     │   │
                  │  └────────────┬─────────────┘   │
                  └───────────────┼─────────────────┘
                                  │ has policies attached
                                  │
                ┌─────────────────┼──────────────────┐
                │                 │                  │
                ▼                 ▼                  ▼
  ┌──────────────────────┐  ┌──────────────┐  ┌──────────────────────────┐
  │ AWS-Managed Policy   │  │ AWS-Managed  │  │ Custom Inline Policy     │
  │ AmazonSSMManaged-    │  │ CloudWatch-  │  │ AssumeProjectRoles       │
  │ InstanceCore         │  │ AgentServer- │  │ (sts:AssumeRole on       │
  │                      │  │ Policy       │  │  cloudhunt-dev, etc.)    │
  └──────────────────────┘  └──────────────┘  └──────────────────────────┘
```

Why three policies and not one big one?

- **`AmazonSSMManagedInstanceCore`**: AWS-managed policy. Includes everything the SSM agent needs to register, send heartbeats, accept sessions, and send command output. AWS maintains it, so as SSM evolves, your permissions automatically stay correct.
- **`CloudWatchAgentServerPolicy`**: AWS-managed. Lets the CloudWatch agent publish custom metrics (memory, disk) and logs. We'll use this in Phase 3.
- **`AssumeProjectRoles` custom inline**: Specific to SandCastle. Lets the instance assume project-specific roles (`cloudhunt-dev`, `cricket-zone-dev`, etc.). This is the "least privilege gateway" — the instance has minimal permissions itself; project work happens under role assumption.

## Step 2: Build the IAM module (40 min)

Create `terraform/modules/iam/main.tf`:

```hcl
# ---- Trust Policy ----
# Who can assume the role? Only the EC2 service.
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ---- The Role ----
resource "aws_iam_role" "keep" {
  name               = "sandcastle-keep-role"
  description        = "Role attached to the SandCastle keep via instance profile"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "sandcastle-keep-role"
  }
}

# ---- AWS-Managed Policies ----
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.keep.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.keep.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ---- Custom Inline Policy: Assume Project Roles ----
# Permits the keep to assume specific project roles. Currently a placeholder
# until project roles exist; will be tightened in a later phase.
data "aws_iam_policy_document" "assume_project_roles" {
  statement {
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = var.project_role_arns
  }

  # Self-discovery: lets scripts on the instance identify themselves.
  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "assume_project_roles" {
  name   = "AssumeProjectRoles"
  role   = aws_iam_role.keep.id
  policy = data.aws_iam_policy_document.assume_project_roles.json
}

# ---- Instance Profile ----
# An instance profile is the "container" that lets an EC2 instance use a role.
resource "aws_iam_instance_profile" "keep" {
  name = "sandcastle-keep-profile"
  role = aws_iam_role.keep.name

  tags = {
    Name = "sandcastle-keep-profile"
  }
}
```

Create `terraform/modules/iam/variables.tf`:

```hcl
variable "project_role_arns" {
  description = "List of project-specific role ARNs that the keep can assume"
  type        = list(string)
  default     = []
}
```

Create `terraform/modules/iam/outputs.tf`:

```hcl
output "instance_profile_name" {
  description = "Name of the IAM instance profile to attach to the keep"
  value       = aws_iam_instance_profile.keep.name
}

output "role_arn" {
  description = "ARN of the IAM role"
  value       = aws_iam_role.keep.arn
}
```

## Step 3: Wire it into the root config (5 min)

Update `terraform/main.tf`:

```hcl
module "networking" {
  source = "./modules/networking"

  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr
  availability_zone  = var.availability_zone
}

module "iam" {
  source = "./modules/iam"

  # Empty for now — project roles get added later as those projects
  # create dedicated dev roles. The custom policy still creates an
  # explicit AssumeRole statement structure for the future.
  project_role_arns = []
}
```

Add to `terraform/outputs.tf`:

```hcl
output "instance_profile_name" {
  value = module.iam.instance_profile_name
}

output "role_arn" {
  value = module.iam.role_arn
}
```

## Step 4: Apply and verify (10 min)

```bash
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

Then verify in IAM console:
- Role `sandcastle-keep-role` exists
- It has 2 AWS managed policies attached + 1 inline policy
- Instance profile `sandcastle-keep-profile` exists and is linked to the role

## Step 5: Quick reading on least privilege (5 min)

The current `project_role_arns` list is empty. That's intentional: project roles don't exist yet. When you eventually create `cloudhunt-dev` and `cricket-zone-dev` roles, you'll add their ARNs here and the keep will be able to assume them — but nothing else.

This is the **principle of least privilege**: grant the minimum permissions needed, and add more only when justified. The opposite anti-pattern is `Action: "*", Resource: "*"` — convenient until it goes wrong.

## Step 6: Commit (2 min)

```bash
git add .
git commit -m "Day 3: IAM module - role, instance profile, AssumeRole policy"
git push
```

## What You Built Today

A complete IAM stack: a role that EC2 can assume, two AWS-managed policies for SSM and CloudWatch, a custom inline policy structure for project role assumption, and the instance profile wrapper that lets EC2 actually use the role.

## End-of-Day Reflection

```markdown
## YYYY-MM-DD — Day 3: IAM module

**What I built**: IAM role, instance profile, SSM + CloudWatch managed policies, AssumeRole policy structure.

**What I learned**: [your words]

**What surprised me**: [your words]

**Stuck moments**: [your words]
```

## Multiple Choice Quiz

**Q1.** You have an IAM role with the right policies attached, but EC2 won't let you assign it directly to an instance. Why not?
- A) The role's trust policy doesn't yet trust the `ec2.amazonaws.com` service
- B) IAM roles can only be attached to Lambda, not EC2
- C) Roles assigned to EC2 must be wrapped in an instance profile — a separate IAM resource that exists specifically to bridge roles and EC2 instances
- D) The role needs an inline policy granting `iam:PassRole` to itself

**Q2.** You're designing the keep's IAM. You can either (a) attach broad permissions for every project directly to the keep's role, or (b) give the keep's role only `sts:AssumeRole` and define separate per-project roles it can assume. Pattern (b) wins primarily because:
- A) Pattern (a) doesn't work — IAM doesn't allow more than 10 policies per role
- B) Pattern (b) enforces project-scoped boundaries with short-lived credentials, and CloudTrail attributes actions to the assumed role for clean per-project audit trails
- C) Pattern (b) is faster at the API level because STS is in-region
- D) Pattern (a) requires writing custom trust policies, which is error-prone

**Q3.** Look at this snippet:
```hcl
assume_role_policy = jsonencode({
  Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
})
```
What is this defining?
- A) The trust relationship: who (or what) is permitted to assume the role — in this case, the EC2 service when launching an instance
- B) Which AWS services the role's credentials can call
- C) Which IAM users can assume the role on a developer's behalf
- D) The session duration policy for credentials issued via assume-role

**Q4.** You write a custom IAM policy that mirrors `AmazonSSMManagedInstanceCore` action-for-action. AWS later adds a new SSM feature requiring an additional permission. What happens to your two instances — one using the AWS-managed policy, one using your custom copy?
- A) Both work fine — AWS auto-grants new SSM permissions to any role with `ssm:*` patterns
- B) Neither works — AWS deprecates the old permission set entirely when adding features
- C) The custom-policy instance works, because IAM uses implicit-allow for new SSM actions
- D) The managed-policy instance works because AWS silently updates `AmazonSSMManagedInstanceCore`; the custom-policy instance breaks until you manually add the new permission

**Q5.** An attacker gets a shell on the keep. The keep's role has only `sts:AssumeRole` for `arn:aws:iam::*:role/cloudhunt-dev`. What is the attacker **not** able to do via AWS APIs?
- A) Read files on the keep's local filesystem
- B) Run arbitrary shell commands on the keep
- C) Call AWS APIs outside the CloudHunt project's scope — they can only operate as `cloudhunt-dev` and within whatever permissions that role grants
- D) View the instance's IAM role ARN via IMDS

<details>
<summary>Answers</summary>

1. **C** — The instance profile wrapper. Note A confuses prerequisites (trust policy *is* needed too, but it's not what blocks attachment). B is just wrong. D invents a self-PassRole requirement.

2. **B** — Boundary enforcement + audit attribution. Note A invents a 10-policy limit (real limit is 20 managed policies, irrelevant here). C is technically true but a trivial benefit. D inverts the truth — pattern (b) actually requires *more* trust policies, not fewer; that's part of the design.

3. **A** — Trust policy definition. Note B describes the permissions policy. C confuses "who can assume" with "which IAM users" (here the principal is a service, not a user). D invents session duration controls (those exist but are a separate field).

4. **D** — AWS manages the lifecycle of managed policies. This is the key reason to prefer managed policies for service-permissions-that-evolve. Note A, B, C invent IAM behaviors that don't exist.

5. **C** — AWS API scope is constrained. Note A and B describe things the attacker *can* do (shell access doesn't go through IAM). D — the instance's role ARN is visible via IMDS by design; that's not gated.

</details>

## Interview Questions

1. **"Explain the difference between an IAM user, role, and instance profile."**
   *Hint: User = long-term identity for a human (with creds). Role = temporary identity assumable by services/users. Instance profile = EC2's mechanism for using a role.*

2. **"How do you implement least privilege for an EC2 instance that needs to access multiple projects?"**
   *Hint: Per-project IAM roles, instance profile permits only AssumeRole, AWS CLI configured with `credential_source = Ec2InstanceMetadata` per profile.*

3. **"What is IMDSv2 and why is it important?"**
   *Hint: Token-based access to the instance metadata service. Prevents SSRF-style attacks that could steal credentials. AWS strongly recommends requiring it.*

4. **"How would you audit which roles a particular instance has used in the last 30 days?"**
   *Hint: CloudTrail logs every `AssumeRole` call. Filter by the instance profile's session name pattern.*

5. **"Walk me through what happens when the AWS CLI on an EC2 instance makes an API call."**
   *Hint: SDK checks credential chain → finds `credential_source = Ec2InstanceMetadata` → IMDSv2 returns temporary creds → SDK uses them. If profile has a `role_arn`, an extra AssumeRole step happens first.*

---

# Day 4 — EC2 Instance with SSM Access

**Time estimate**: 90 minutes
**Prerequisites**: Days 1-3 complete

## Why we're doing this today

Today the abstract becomes concrete: you launch the actual EC2 instance — the keep itself. By the end of today you'll SSH-equivalent into your own cloud Linux box for the first time.

You're learning:

- **EC2 fundamentals**: AMIs, instance types, EBS volumes, IMDSv2
- **The AMI SSM Parameter pattern**: how to avoid hardcoded AMI IDs
- **SSM Session Manager**: how to connect without SSH

## Step 1: Build the compute module (45 min)

Create `terraform/modules/compute/main.tf`:

```hcl
# ---- Resolve latest Amazon Linux 2023 AMI dynamically ----
# Hardcoding AMI IDs goes stale; SSM Parameter Store is updated by AWS.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---- The Keep ----
resource "aws_instance" "keep" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = var.instance_profile_name

  # Require IMDSv2 — prevents SSRF-style metadata credential theft
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "sandcastle-keep-root"
    }
  }

  tags = {
    Name         = "sandcastle-keep"
    AutoStop     = "true"
    BackupPolicy = "daily"
  }

  # Prevent recreate-on-AMI-update: AMI changes shouldn't replace the instance
  # if everything else is the same; we'd rather opt into a rebuild explicitly.
  lifecycle {
    ignore_changes = [ami]
  }
}
```

Create `terraform/modules/compute/variables.tf`:

```hcl
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Size of the root EBS volume in GB"
  type        = number
  default     = 50
}

variable "subnet_id" {
  description = "ID of the subnet to launch the instance into"
  type        = string
}

variable "security_group_id" {
  description = "ID of the security group to attach"
  type        = string
}

variable "instance_profile_name" {
  description = "Name of the IAM instance profile to attach"
  type        = string
}
```

Create `terraform/modules/compute/outputs.tf`:

```hcl
output "instance_id" {
  description = "ID of the keep EC2 instance"
  value       = aws_instance.keep.id
}

output "public_ip" {
  description = "Public IP of the keep (informational only — SG blocks inbound)"
  value       = aws_instance.keep.public_ip
}

output "private_ip" {
  description = "Private IP of the keep"
  value       = aws_instance.keep.private_ip
}
```

## Step 2: Wire it in (5 min)

Update `terraform/main.tf`:

```hcl
module "networking" {
  source = "./modules/networking"

  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr
  availability_zone  = var.availability_zone
}

module "iam" {
  source = "./modules/iam"

  project_role_arns = []
}

module "compute" {
  source = "./modules/compute"

  subnet_id             = module.networking.public_subnet_id
  security_group_id     = module.networking.keep_security_group_id
  instance_profile_name = module.iam.instance_profile_name
}
```

Add to `terraform/outputs.tf`:

```hcl
output "instance_id" {
  value = module.compute.instance_id
}

output "public_ip" {
  value = module.compute.public_ip
}
```

## Step 3: Apply (5 min)

```bash
terraform fmt -recursive
terraform plan
terraform apply
```

The plan should show: 1 instance to create. Apply takes about 60 seconds.

## Step 4: First SSM connection (20 min)

Wait ~90 seconds after apply completes for the SSM agent to register.

Verify it's online:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$(terraform output -raw instance_id)" \
  --profile sandcastle
```

You should see your instance with `"PingStatus": "Online"`. If not, wait another 30 seconds and retry.

Now connect:

```bash
aws ssm start-session --target $(terraform output -raw instance_id) --profile sandcastle
```

You're in! You should see something like:

```
Starting session with SessionId: hussain-xxxxxxxxx
sh-5.2$
```

Try a few commands:

```bash
whoami         # ssm-user (default SSM session user)
cat /etc/os-release   # Amazon Linux 2023
df -h          # disk layout
free -h        # RAM
uname -a       # kernel
```

Exit:

```bash
exit
```

## Step 5: Create a helper connect script (10 min)

Create `scripts/connect.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Day 0 discipline: profile must be explicit. Default to sandcastle for this script
# since it's project-specific, but error clearly if SSO token has expired.
AWS_PROFILE="${AWS_PROFILE:-sandcastle}"

INSTANCE_ID=$(terraform -chdir=terraform output -raw instance_id 2>/dev/null)

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Could not get instance ID from Terraform output."
  exit 1
fi

STATE=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --profile "$AWS_PROFILE" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text)

if [[ "$STATE" != "running" ]]; then
  echo "Instance is $STATE. Starting..."
  aws ec2 start-instances --instance-ids "$INSTANCE_ID" --profile "$AWS_PROFILE" > /dev/null
  aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --profile "$AWS_PROFILE"
fi

echo "Connecting to $INSTANCE_ID via SSM..."
aws ssm start-session --target "$INSTANCE_ID" --profile "$AWS_PROFILE"
```

```bash
chmod +x scripts/connect.sh
```

Test it:

```bash
./scripts/connect.sh
```

## Step 6: Commit (5 min)

```bash
git add .
git commit -m "Day 4: Compute module - EC2 keep with SSM access"
git push
```

## What You Built Today

A running EC2 instance accessible via SSM Session Manager, with IMDSv2 enforced, encrypted EBS, and a helper script for one-command connection.

## End-of-Day Reflection

```markdown
## YYYY-MM-DD — Day 4: EC2 + SSM

**What I built**: t3.medium instance, gp3 encrypted root volume, IMDSv2 enforced, SSM-accessible.

**What I learned**: [your words]

**What surprised me**: [your words]

**Stuck moments**: [your words]
```

## Multiple Choice Quiz

**Q1.** Your Terraform pulls the AMI ID from `data.aws_ssm_parameter.al2023_ami`. A colleague proposes hardcoding the AMI ID instead, arguing "it'll be reproducible." Why is the SSM Parameter pattern the better choice for a long-lived dev environment?
- A) Hardcoded AMIs can't be used with `lifecycle.ignore_changes`
- B) AWS publishes new AL2023 AMI versions regularly with security patches; the SSM parameter always resolves to the current one, so new instances boot with the latest patched image
- C) Hardcoded AMIs work only within the region where they were created
- D) The SSM Parameter Store charges nothing for parameter reads; hardcoded AMIs trigger a per-instance lookup fee

**Q2.** What does `http_tokens = "required"` in the EC2 instance's `metadata_options` actually enforce?
- A) HTTPS for all instance metadata service requests (TLS encryption end-to-end)
- B) Token-based authentication for AWS API calls made from the instance
- C) Mutual TLS between the SSM agent and the SSM service
- D) IMDSv2 only: every metadata request must include a session token obtained via a `PUT` to `/latest/api/token`, which blocks SSRF-style credential theft because attackers can't forge a `PUT` through a vulnerable application

**Q3.** You launched an EC2 instance in a public subnet with `map_public_ip_on_launch = true`. The security group has zero inbound rules. How does SSM Session Manager get a shell to you?
- A) AWS Console proxies the shell through your instance's public IP; security groups don't apply to AWS-managed services
- B) The instance's `metadata_options` block opens a backchannel for SSM
- C) The SSM agent on the instance maintains an outbound WebSocket to the SSM regional endpoint over the public IP; your console session is proxied through that pre-existing outbound connection
- D) SSM uses a special "management ENI" that bypasses the user's security groups

**Q4.** The `lifecycle { ignore_changes = [ami] }` block on your `aws_instance` exists because:
- A) Without it, every `terraform apply` would trigger an instance replacement whenever the SSM-resolved AMI updates — destroying the running OS and any in-flight work on the EBS root volume
- B) Terraform's diff engine doesn't understand AMI IDs and would otherwise error out
- C) The AWS provider explicitly requires it for SSM-resolved AMIs
- D) Without it, the instance can't be stopped and started — only terminated

**Q5.** Your `t3.medium` instance has a `gp3` root EBS volume. You run `aws ec2 stop-instances` to save money overnight. What happens to your data the next morning when you start the instance?
- A) The volume is detached at stop and reattached at start; data persists but the volume ID changes
- B) The volume is snapshotted at stop and restored at start (paid as snapshot storage between stop and start)
- C) Nothing happens to the volume — EBS storage is independent of instance run state; your data is exactly where you left it
- D) The volume is wiped because gp3 volumes are ephemeral by default

<details>
<summary>Answers</summary>

1. **B** — Patch currency. Note A invents a `lifecycle` constraint. C is wrong — both AMI IDs and SSM parameters are region-scoped, that's not a differentiator. D invents a fee that doesn't exist (Parameter Store standard tier is free).

2. **D** — IMDSv2 mechanics. Note A confuses transport encryption (TLS) with the session-token model. B and C invent unrelated authentication scopes.

3. **C** — Outbound-initiated rendezvous. Note A is wrong about security groups (they absolutely apply to all traffic including AWS-managed). B confuses metadata service with SSM. D invents a "management ENI."

4. **A** — Avoiding destructive replacement on AMI updates. Note B, C, D invent constraints that don't exist.

5. **C** — EBS persistence model. Note A is wrong — the volume stays attached at stop, and the volume ID doesn't change. B confuses EBS with instance-store. D invents a "gp3 is ephemeral" claim that's the opposite of reality.

</details>

## Interview Questions

1. **"How do you handle AMI updates in Terraform without recreating instances every time AWS publishes a new image?"**
   *Hint: `lifecycle { ignore_changes = [ami] }` for in-place stability; explicit rebuilds when you actually want the update.*

2. **"What is IMDSv2 and what attack does it prevent?"**
   *Hint: Token-based metadata service. Prevents SSRF (server-side request forgery) attacks from stealing instance credentials.*

3. **"Why use gp3 over gp2 for EBS?"**
   *Hint: gp3 is cheaper per GB, decouples IOPS/throughput from size, has predictable baseline performance.*

4. **"Walk me through what happens when an EC2 instance starts up."**
   *Hint: AMI boots, network interface attaches, instance profile is associated, user data runs as root, SSM agent starts and registers.*

5. **"How would you connect to an EC2 instance that has no public IP and no SSH key configured?"**
   *Hint: SSM Session Manager, provided the instance has the SSM agent + an instance profile with `AmazonSSMManagedInstanceCore` + outbound internet (or VPC endpoints) to reach SSM endpoints.*

---

# Day 5 — User Data and Toolchain Bootstrap

**Time estimate**: 90 minutes
**Prerequisites**: Day 4 complete

## Why we're doing this today

Right now your keep is a bare Amazon Linux 2023 box. Every time you rebuild it, you'd have to install Terraform, AWS CLI, Node, Python, git, tmux, Docker — all by hand. That's slow, error-prone, and not reproducible.

**User data** is a script that EC2 runs on first boot as root. By the end of today, every new keep you build is fully equipped on first boot — no manual setup.

You're learning:

- **User data execution model**: how, when, and as whom it runs
- **`cloud-init` basics** (the framework Amazon Linux uses for user data)
- **Idempotent shell scripting** (so it's safe even if re-run)
- **The bootstrap-marker pattern** (verifying user data completed successfully)

## Step 1: Write the bootstrap script (50 min)

Create `scripts/bootstrap-instance.sh`:

```bash
#!/usr/bin/env bash
#
# bootstrap-instance.sh
# Runs as root on the keep's first boot via EC2 user data.
# Installs the developer toolchain. Idempotent.

set -euo pipefail
exec > >(tee -a /var/log/sandcastle-bootstrap.log) 2>&1

echo "==> SandCastle bootstrap starting at $(date -u)"

# ---- Update base system ----
dnf -y update

# ---- Install base tools ----
dnf -y install \
  git \
  tmux \
  jq \
  unzip \
  tar \
  gzip \
  wget \
  htop \
  tree \
  python3.12 \
  python3-pip \
  docker

# ---- Enable Docker (without starting it on every boot for personal use) ----
systemctl enable docker

# ---- Node.js 20 via NodeSource ----
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
  dnf -y install nodejs
fi

# ---- Terraform via HashiCorp YUM repo ----
if ! command -v terraform >/dev/null 2>&1; then
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
  dnf -y install terraform
fi

# ---- AWS CLI v2 ----
if ! command -v aws >/dev/null 2>&1; then
  cd /tmp
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip -q awscliv2.zip
  ./aws/install
  rm -rf aws awscliv2.zip
fi

# ---- pre-commit ----
pip3 install --quiet pre-commit

# ---- Create the hussain user ----
if ! id -u hussain >/dev/null 2>&1; then
  useradd -m -s /bin/bash hussain
  echo 'hussain ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/hussain
  chmod 0440 /etc/sudoers.d/hussain
fi

# ---- Configure shell defaults for hussain ----
sudo -u hussain bash <<'EOF'
mkdir -p ~/dev ~/.ssh
chmod 700 ~/.ssh

# Pre-trust GitHub host key (avoids the "yes/no" prompt on first git clone)
ssh-keyscan -t ed25519,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null

# Useful shell aliases
cat > ~/.bashrc <<'BASHRC'
# .bashrc

# User specific aliases
alias ll='ls -lah'
alias gs='git status'
alias gd='git diff'
alias gc='git commit'
alias tf='terraform'
alias k='kubectl'

# Show AWS profile in prompt
export PS1='\u@sandcastle:\w$([ -n "$AWS_PROFILE" ] && echo " ($AWS_PROFILE)" )\$ '

# Source bash completions
[ -f /etc/bash_completion ] && . /etc/bash_completion

BASHRC

# tmux config
cat > ~/.tmux.conf <<'TMUX'
set -g default-terminal "screen-256color"
set -g history-limit 50000
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
TMUX

EOF

# ---- Marker file ----
touch /var/log/sandcastle-bootstrap.complete
echo "==> SandCastle bootstrap complete at $(date -u)"
```

```bash
chmod +x scripts/bootstrap-instance.sh
```

**Why idempotent (each install wrapped in `if ! command -v ...`)?** User data normally runs only once, but during development you might want to re-run it manually. Idempotent scripts can be run twice without breaking anything.

**Why a marker file?** When you SSH in, you can `cat /var/log/sandcastle-bootstrap.complete` to verify the script finished successfully. If the file doesn't exist, the script failed somewhere — check `/var/log/sandcastle-bootstrap.log`.

## Step 2: Attach user data to the instance (10 min)

Update `terraform/modules/compute/main.tf` — add a `user_data` argument to `aws_instance.keep`:

```hcl
resource "aws_instance" "keep" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = var.instance_profile_name

  # NEW: user data
  user_data = var.user_data
  # Force a re-run if the script changes
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "sandcastle-keep-root"
    }
  }

  tags = {
    Name         = "sandcastle-keep"
    AutoStop     = "true"
    BackupPolicy = "daily"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
```

Add the variable in `terraform/modules/compute/variables.tf`:

```hcl
variable "user_data" {
  description = "User data script for first-boot bootstrap"
  type        = string
  default     = null
}
```

Update `terraform/main.tf` to pass the script in:

```hcl
module "compute" {
  source = "./modules/compute"

  subnet_id             = module.networking.public_subnet_id
  security_group_id     = module.networking.keep_security_group_id
  instance_profile_name = module.iam.instance_profile_name
  user_data             = file("${path.module}/../scripts/bootstrap-instance.sh")
}
```

**About `user_data_replace_on_change`**: When this is `true`, if you modify the bootstrap script, Terraform will *recreate* the instance (because user data only runs on first boot — modifying it has no effect on a running instance). This is the correct behavior, but be aware: on apply, your instance gets replaced and you lose anything you'd added locally. Best practice is to develop the bootstrap script carefully, then re-run only when you've made meaningful changes.

## Step 3: Apply (10 min)

```bash
terraform plan
# You should see: 1 instance to REPLACE (destroy + create)
```

This is the moment to be intentional. Your existing keep gets destroyed and replaced. Since you haven't put anything important on it yet, this is fine. In future, you'd take a snapshot first.

```bash
terraform apply
```

Wait ~4 minutes for the new instance to boot AND user data to complete.

## Step 4: Verify the bootstrap (15 min)

Connect via SSM:

```bash
./scripts/connect.sh
```

Inside the session, become the `hussain` user and verify:

```bash
sudo su - hussain

# Check tools installed
terraform version
aws --version
node --version
python3 --version
git --version
docker --version
tmux -V

# Check bootstrap marker
cat /var/log/sandcastle-bootstrap.complete

# Check the bootstrap log
sudo cat /var/log/sandcastle-bootstrap.log | tail -50
```

If everything's there, you're done. If something failed, the log tells you what.

## Step 5: Commit (5 min)

```bash
exit  # leave hussain user
exit  # leave SSM session

git add .
git commit -m "Day 5: User data bootstrap - toolchain auto-installed on first boot"
git push
```

## What You Built Today

Reproducible first-boot toolchain installation. Every rebuild of the keep produces an identical, ready-to-use dev environment.

## End-of-Day Reflection

```markdown
## YYYY-MM-DD — Day 5: User data bootstrap

**What I built**: Bootstrap shell script with idempotent installs, marker file, user creation, shell config.

**What I learned**: [your words]

**What surprised me**: [your words]

**Stuck moments**: [your words]
```

## Multiple Choice Quiz

**Q1.** You add a new package install to the user data script and run `terraform apply`. The instance keeps running with the *old* configuration. Why?
- A) The SSM agent caches the user data and serves the cached version
- B) User data only runs on first boot. The existing instance is past first boot, so the change is inert until you replace the instance (or set `user_data_replace_on_change = true`)
- C) Terraform applies the user data change asynchronously over the next 24 hours
- D) Cloud-init refuses to re-run user data once a successful boot is recorded in `/var/lib/cloud/instances/`

**Q2.** Cloud-init executes user data as which user, and why does that matter for your bootstrap script?
- A) As `ec2-user` (the default login user), which means `sudo` is required for any system-level operation
- B) As an isolated `cloud-init` system user, requiring you to write SUID binaries for privileged operations
- C) As root, because cloud-init runs early in the boot sequence before user logins exist; system package installs (which require root) work directly without `sudo`
- D) As whichever user the SSM agent was registered with; this defaults to `ec2-user` on AL2023

**Q3.** You add `user_data_replace_on_change = true` to your `aws_instance`. You change the user data script and run `terraform apply`. What happens?
- A) Terraform destroys the existing instance and creates a new one — the new instance boots fresh and runs the updated user data as part of its first boot
- B) The existing instance reboots and re-runs user data
- C) Terraform refuses to apply, since user data changes are destructive
- D) Cloud-init detects the new script via IMDS and re-executes it without instance replacement

**Q4.** Your bootstrap script installs Docker. You run the script a second time on the same instance (for testing). Without idempotency, what's the most likely real-world failure?
- A) The script fails partway through because the second `apt-get install docker.io` errors on the already-installed package
- B) The script duplicates Docker, leaving two installations
- C) Cloud-init blocks repeated execution to prevent corruption
- D) The script silently corrupts the Docker installation by re-running setup steps that assume a clean state — like adding a user to the `docker` group twice or appending duplicate lines to config files

**Q5.** Why does the bootstrap script `touch /var/log/sandcastle-bootstrap.complete` at the very end?
- A) Cloud-init requires a completion marker to flag boot as successful
- B) SSM Session Manager won't allow connections until this file exists
- C) It's a simple, idempotent boolean check: a quick `ls` on the file tells you the script ran end-to-end, without needing to grep through 500 lines of cloud-init logs
- D) The CloudWatch agent watches this file and emits a metric when it appears

<details>
<summary>Answers</summary>

1. **B** — User data runs only on first boot. Note A invents SSM caching behavior. C invents an asynchronous-apply behavior. D is half-true (cloud-init does check `/var/lib/cloud/instances/`) but framed misleadingly — the issue isn't cloud-init refusing, it's that Terraform doesn't pass the new user data to the existing instance at all.

2. **C** — Root by default. Note A is the post-boot login user, not the cloud-init context. B and D are invented.

3. **A** — Instance replacement. Note B is the *desired* behavior, but not what actually happens — user data really does only run on first boot. C is wrong, Terraform doesn't refuse. D is invented.

4. **D** — The silent-corruption failure mode. Note A is plausible-sounding but wrong: `apt-get install` on an already-installed package is a no-op, it doesn't error. The real risks are appending-twice or group-membership-twice bugs.

5. **C** — Simple operational signal. Note A, B, D invent dependencies that don't exist. The marker is just a convention you make yourself for fast verification.

</details>

## Interview Questions

1. **"How do you ensure a new EC2 instance has the right software installed when it boots?"**
   *Hint: User data + idempotent shell scripts, or for more complex needs, golden AMIs (pre-baked images), or configuration management tools (Ansible, Chef).*

2. **"User data vs golden AMI — when do you use which?"**
   *Hint: User data is flexible and easy to update; golden AMIs boot faster and are more reproducible. Common pattern: golden AMI for the heavy stuff (OS hardening, slow installs), user data for instance-specific config.*

3. **"What does idempotent mean in a script context, and why does it matter for cloud bootstrapping?"**
   *Hint: Idempotent = running multiple times produces the same result as running once. Critical because retries are common and you don't want partial-state corruption.*

4. **"How would you debug a failed user data script after the instance launched?"**
   *Hint: Check `/var/log/cloud-init-output.log`, `/var/log/cloud-init.log`, your custom log file. SSM into the instance even if user data failed (assuming the SSM agent installed before the failure).*

5. **"What's the difference between user data and instance metadata?"**
   *Hint: User data = script you provide that runs on first boot. Metadata = info about the instance (IP, IAM role, tags) available via the IMDS endpoint.*

---

# Day 6 — Project Migration: CloudHunt on SandCastle

**Time estimate**: 75 minutes
**Prerequisites**: Day 5 complete

## Why we're doing this today

The keep exists, it has a toolchain, you can SSM into it. Now the proof: can you actually do real work from it? Today you migrate CloudHunt onto SandCastle and run a `terraform plan` from inside the keep against the real CloudHunt state in S3.

You're learning:

- **Cross-project access patterns** (the keep manages CloudHunt's AWS resources)
- **Git on a remote box** (SSH key generation, GitHub setup)
- **VS Code Remote-SSH/Tunnels over SSM** (so you can edit code with a real editor)

## Step 1: Set up Git on the keep (15 min)

Connect:

```bash
./scripts/connect.sh
sudo su - hussain
```

Generate an SSH key for GitHub:

```bash
ssh-keygen -t ed25519 -C "hussain@sandcastle" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```

Copy the public key output. On your laptop, open GitHub → Settings → SSH and GPG keys → New SSH key. Title: "SandCastle keep". Paste. Save.

Back in the SSM session, test:

```bash
ssh -T git@github.com
# Should respond: "Hi nainashee! You've successfully authenticated..."
```

Configure git:

```bash
git config --global user.name "Hussain Ashfaque"
git config --global user.email "your.email@example.com"
git config --global init.defaultBranch main
```

## Step 2: Clone CloudHunt (10 min)

```bash
cd ~/dev
git clone git@github.com:nainashee/cloudhunt.git
cd cloudhunt
ls -la
```

You should see your CloudHunt project structure. Check that pre-commit can install:

```bash
pre-commit install
```

## Step 3: Configure AWS credentials on the keep (15 min)

This is the moment where the IAM design pays off. You're not putting access keys on the keep. Instead, the keep uses its instance profile.

Verify the instance profile is providing credentials:

```bash
aws sts get-caller-identity
```

You should see your instance profile ARN as the caller (something like `arn:aws:sts::989126024881:assumed-role/sandcastle-keep-role/i-xxx`).

Now configure a profile for CloudHunt work. Since you don't yet have a dedicated `cloudhunt-dev` role (that's a future improvement), for now the instance profile itself has the broad permissions needed.

Create `~/.aws/config`:

```bash
mkdir -p ~/.aws
cat > ~/.aws/config <<'EOF'
[default]
region = us-east-1
credential_source = Ec2InstanceMetadata

[profile cloudhunt]
region = us-east-1
credential_source = Ec2InstanceMetadata
EOF
```

**Note on profile naming**: These profile names live only on the keep — they're not the same as your laptop's SSO profiles (which are `sandcastle`, `cloudhunt`, `launchpad-sso`, `playhowzat` per Day 0). The keep uses `credential_source = Ec2InstanceMetadata`, which gets credentials from the keep's instance profile, not from any SSO session. The profile names here just give CloudHunt's Terraform a name to reference.

**Heads-up on existing CloudHunt code**: Your existing CloudHunt Terraform may still reference `--profile launchpad` from before Day 0. If it does, you have two clean options:
1. Update the CloudHunt repo to use `cloudhunt` consistently (recommended — matches Day 0 naming everywhere)
2. Add a `[profile launchpad]` stanza to the keep's config as a temporary alias while you migrate CloudHunt

Track this as tech debt in CloudHunt's `LEARNINGS.md`.

**Note**: Right now your IAM role only has SSM + CloudWatch + AssumeRole permissions. For CloudHunt's Terraform to actually plan/apply, you'd either need to (a) broaden the keep's role temporarily, or (b) create a `cloudhunt-dev` role and add its ARN to `project_role_arns` in the IAM module. For today's exercise, just confirm that `terraform init` works (it only needs S3 + DynamoDB access for state). Full project apply is a future task.

## Step 4: Initialize CloudHunt from the keep (10 min)

```bash
cd ~/dev/cloudhunt/terraform/envs/dev
terraform init
```

This should pull state from the `jobhunt-terraform-state-989126024881` bucket. If init succeeds, you've proven:

- The keep can reach S3
- IAM permissions work
- Terraform on the keep can manage CloudHunt's state

This is your "SandCastle is alive and useful" moment.

## Step 5: Set up VS Code Remote-Tunnels (15 min)

VS Code on your work laptop can connect to the keep without exposing any ports.

On the keep (in the SSM session):

```bash
# Install VS Code CLI
curl -L "https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-x64" -o vscode-cli.tar.gz
tar -xzf vscode-cli.tar.gz
sudo mv code /usr/local/bin/
rm vscode-cli.tar.gz

# Start a tunnel (one-time setup; uses your GitHub login)
code tunnel
```

Follow the GitHub device-auth flow. Give the tunnel a name (e.g., `sandcastle-keep`). On your laptop's VS Code, install the "Remote - Tunnels" extension, then "Remote-Tunnels: Connect to Tunnel" → select `sandcastle-keep`.

You're now editing code on the keep with full VS Code support — IntelliSense, extensions, terminal — without any SSH or open ports.

For persistent tunnels (so you don't have to re-launch every session), set up as a systemd service later. For now, run `code tunnel` inside a tmux session so it survives SSM disconnects.

## Step 6: Commit (5 min)

```bash
# On the keep:
exit  # leave hussain
exit  # leave SSM

# Back on laptop:
git add .
git commit -m "Day 6: Project migration setup - CloudHunt running from SandCastle"
git push
```

## What You Built Today

CloudHunt running from inside SandCastle. Git, SSH keys, VS Code Remote-Tunnels — full real-world dev workflow.

## End-of-Day Reflection

```markdown
## YYYY-MM-DD — Day 6: Project migration

**What I built**: GitHub SSH on keep, CloudHunt cloned, terraform init successful, VS Code Remote-Tunnels working.

**What I learned**: [your words]

**What surprised me**: [your words]

**Stuck moments**: [your words]
```

## Multiple Choice Quiz

**Q1.** You're cloning CloudHunt onto the keep via Git. Instead of copying your laptop's SSH key over, you generate a fresh keypair on the keep and add the public key to GitHub. The primary security benefit is:
- A) GitHub rate-limits clones from reused keys, so a fresh key is faster
- B) GitHub requires unique keys per host
- C) Per-host keys give you per-host revocation: if the keep is compromised or decommissioned, you remove one GitHub-registered key without touching your laptop's access
- D) Fresh keys use a stronger algorithm than older laptop keys by default

**Q2.** Your `~/.aws/config` on the keep includes `credential_source = Ec2InstanceMetadata`. What does this line cause the AWS SDK / CLI to do?
- A) Read AWS credentials from `~/.aws/credentials` and fall back to IMDS if the file is missing
- B) Skip the credentials file entirely and fetch credentials directly from the EC2 Instance Metadata Service (IMDSv2), which serves short-lived credentials minted from the instance profile's role
- C) Use the AWS SSO session cached on the keep (matching the laptop's SSO model)
- D) Pull credentials from AWS Secrets Manager using the instance's IAM role

**Q3.** You install VS Code Remote-Tunnels on the keep, run `code tunnel`, and on your laptop connect to the same tunnel. No inbound port is open on the keep's security group. How does this work?
- A) Microsoft's tunnel service runs over UDP, which bypasses TCP-based security groups
- B) VS Code's tunnel auto-creates a transient inbound rule in your security group at session start
- C) The tunnel uses ICMP, which security groups treat as always-allow
- D) The tunnel uses an outbound-initiated WebSocket from the keep to Microsoft's relay service; your laptop also connects outbound to the same service. Both sides connect *out*, the service brokers the rendezvous — same pattern as SSM Session Manager, ngrok, and Tailscale

**Q4.** Imagine you put long-lived IAM access keys in `~/.aws/credentials` on the keep instead of relying on `credential_source = Ec2InstanceMetadata`. What's the realistic risk profile?
- A) Slower API calls because static keys require an extra STS exchange on each request
- B) The keys are stored cleartext on disk; an EBS snapshot, a misconfigured backup, or a compromised process running as your user can read them. Rotation is manual and tied to your discipline, not AWS's
- C) AWS will alert you within minutes if static keys are present on an EC2 instance
- D) Static keys silently expire after 72 hours, breaking your tooling unannounced

**Q5.** You clone a repo with a `.pre-commit-config.yaml` file onto the keep. The hooks (e.g., `terraform fmt`, `yamllint`) don't run when you commit. Why?
- A) The repo's `.git/hooks/` directory wasn't included in the clone — pre-commit hooks are installed locally per checkout, not stored in the repo itself. You need to run `pre-commit install` on the keep to register them
- B) Git ignores pre-commit hooks for SSM-connected sessions
- C) `terraform fmt` requires write permissions to the IAM role
- D) Pre-commit only works inside a Python virtualenv

<details>
<summary>Answers</summary>

1. **C** — Per-host revocation. Note A, B, D invent constraints that don't exist.

2. **B** — IMDS credential source. Note A misframes the precedence (this directive *replaces* the credentials file, doesn't fall back to it). C is wrong — SSO isn't involved on the keep. D invents Secrets Manager involvement.

3. **D** — Outbound rendezvous pattern. Note A is wrong (the tunnel uses TCP/WebSocket over 443). B invents auto-rule creation that would be a security disaster if true. C invents an ICMP-based approach.

4. **B** — Cleartext-on-disk risk. Note A invents a performance claim. C invents an AWS alerting feature (GuardDuty does flag *exposed* keys but not just on-disk presence). D invents an auto-expiry that doesn't exist.

5. **A** — pre-commit hooks are per-checkout. Note B, C, D invent constraints.

</details>

## Interview Questions

1. **"How do you handle Git authentication on ephemeral or shared compute resources?"**
   *Hint: Per-host SSH keys, short-lived deploy tokens for CI, or SSH certificates from a CA for fully ephemeral hosts.*

2. **"You're remote-developing on a cloud VM. How do you avoid exposing it to the internet?"**
   *Hint: SSM Session Manager, VS Code Remote-Tunnels, Tailscale, or AWS Client VPN. All outbound-initiated.*

3. **"How would you give an EC2 instance the ability to manage resources for multiple AWS projects without making it omnipotent?"**
   *Hint: Per-project IAM roles, instance profile permits only `AssumeRole` for those roles, profile-based AWS CLI config with `credential_source = Ec2InstanceMetadata`.*

4. **"What's the failure mode if `terraform init` can't connect to its remote state backend?"**
   *Hint: Init fails. Without state, Terraform can't plan or apply. Network connectivity, IAM permissions on the state bucket, and DynamoDB lock table availability all matter.*

5. **"Walk me through your IAM model for a multi-project personal AWS environment."**
   *Hint: Instance profile → role with minimal direct perms → AssumeRole on per-project roles → each project role has scoped permissions. CloudTrail logs every assume.*

---

# Day 7 — Polish, Documentation, and Phase 1 Wrap

**Time estimate**: 60 minutes
**Prerequisites**: Days 1-6 complete

## Why we're doing this today

Phase 1 is functionally complete. Today is about turning it from "it works" into "it's portfolio-ready." The difference between a tutorial project and a portfolio piece is whether someone landing on the repo cold can immediately understand what it is, why it matters, and how to run it.

You're learning:

- **README discipline**: front-matter, badges, screenshots, command examples
- **Output hygiene**: surfacing useful values via `terraform output`
- **Tag audits**: making sure every resource is correctly tagged for cost allocation
- **The "polish day" mindset**: budgeting time for finishing, not just building

## Step 1: Audit all resources for proper tagging (10 min)

From your laptop:

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Project,Values=sandcastle" \
  --profile sandcastle \
  --query 'ResourceTagMappingList[*].[ResourceARN]' \
  --output table
```

You should see every SandCastle resource listed: VPC, subnet, IGW, route table, security group, IAM role, instance profile, EC2 instance, EBS volume.

If anything is missing, add the appropriate `tags` block to the corresponding Terraform resource and re-apply.

## Step 2: Add useful Terraform outputs (10 min)

Update `terraform/outputs.tf` to surface everything you'd want at your fingertips:

```hcl
output "instance_id" {
  description = "ID of the keep EC2 instance"
  value       = module.compute.instance_id
}

output "public_ip" {
  description = "Public IP (informational; SG blocks all inbound)"
  value       = module.compute.public_ip
}

output "private_ip" {
  description = "Private IP of the keep"
  value       = module.compute.private_ip
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "instance_profile_name" {
  description = "Name of the IAM instance profile"
  value       = module.iam.instance_profile_name
}

output "ssm_connect_command" {
  description = "Run this to connect via SSM"
  value       = "aws ssm start-session --target ${module.compute.instance_id} --profile sandcastle"
}
```

Apply:

```bash
terraform apply
terraform output
```

You should see all outputs printed. `terraform output -raw ssm_connect_command` is now a one-liner you can pipe to bash if you want.

## Step 3: Update the README with real values (15 min)

Update the README:

- Replace placeholder IDs with real values from `terraform output`
- Add a "Verified working" badge or section
- Add a screenshot of the AWS console showing the running instance (optional but high-impact for portfolio)

You already have a solid README from the documentation phase. Today's edits are just filling in the now-real values and adding any "lessons learned" notes.

## Step 4: Update LEARNINGS.md with the full Phase 1 retrospective (10 min)

```markdown
## YYYY-MM-DD — Phase 1 Complete

**What I built across 7 days**:
- Terraform state backend (S3 + DynamoDB)
- VPC with public subnet, IGW, no-ingress security group
- IAM role + instance profile with SSM, CloudWatch, AssumeRole
- t3.medium EC2 instance with gp3 encrypted storage, IMDSv2 required
- User data bootstrap installing full dev toolchain
- CloudHunt successfully running from the keep
- VS Code Remote-Tunnels working

**Biggest lessons**:
- [your words — what was hardest, what clicked, what would you tell yourself on Day 1]

**Things I want to revisit**:
- [your words]

**Stuck moments I survived**:
- [your words]

**Phase 2 entry criteria met**:
- [x] Keep is reachable via SSM
- [x] Toolchain auto-installs on rebuild
- [x] CloudHunt's state is accessible from the keep
- [x] All resources tagged Project=sandcastle
```

## Step 5: Tag the release (5 min)

```bash
git tag -a v0.1.0 -m "Phase 1: Foundation complete"
git push --tags
```

Now your repo has a real, point-in-time milestone. Future commits move forward; v0.1.0 is the "Phase 1 done" snapshot.

## Step 6: Sanity-check the cost (5 min)

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -d '7 days ago' +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
  --granularity DAILY \
  --metrics UnblendedCost \
  --filter '{"Tags": {"Key": "Project", "Values": ["sandcastle"]}}' \
  --profile sandcastle
```

You should see daily costs around $1 (since you've been running 24/7 during the build). This confirms cost allocation tagging is working.

## Step 7: Set up your daily workflow alias (5 min)

On your laptop, add this to `~/.bashrc` or `~/.zshrc`:

```bash
alias castle='cd ~/dev/sandcastle && ./scripts/connect.sh'
alias castle-up='aws ec2 start-instances --instance-ids $(terraform -chdir=$HOME/dev/sandcastle/terraform output -raw instance_id) --profile sandcastle'
alias castle-down='aws ec2 stop-instances --instance-ids $(terraform -chdir=$HOME/dev/sandcastle/terraform output -raw instance_id) --profile sandcastle'
```

Now `castle` connects you in one word.

## What You Built Across Phase 1

A fully working, documented, portfolio-grade personal AWS development environment with:

- Modular Terraform code
- Reproducible state backend
- VPC with thoughtful security posture
- Least-privilege IAM
- SSM-only access (no SSH, no inbound ports)
- Auto-installing toolchain
- CloudHunt successfully migrated
- All resources properly tagged
- VS Code Remote-Tunnels for full IDE experience

## End-of-Phase Quiz (Cumulative)

**Q1.** An interviewer asks: "Of all the security controls in SandCastle's design — encrypted EBS, IMDSv2 enforcement, zero-ingress security group, CloudTrail logging, instance-profile-only credentials — which one provides the most fundamental protection, and why?" The strongest answer is:
- A) Encrypted EBS volumes, because data-at-rest is the foundation of every modern security framework
- B) IMDSv2 enforcement, because SSRF is the most common cloud-native attack vector
- C) CloudTrail logging, because without an audit trail you can't detect or respond to incidents
- D) Zero-ingress security group paired with SSM access, because eliminating the network attack surface entirely means there's nothing to attack remotely; every other control is defense-in-depth for an attack that can't reach the box in the first place

**Q2.** Phase 2 will add an EventBridge schedule + auto-stop Lambda to shut the keep down on a fixed schedule. From the cost analysis we did, why is this the single largest cost lever in SandCastle?
- A) Lambda execution itself drives most cloud costs at small scale
- B) EC2 compute is roughly 80% of the always-on bill; cutting runtime by ~75% directly compresses that dominant line item. EBS, data transfer, and Lambda are all minor by comparison.
- C) Auto-stop eliminates the EBS volume between sessions, removing the second-biggest cost line
- D) Stopping the instance pauses data transfer charges that would otherwise accumulate continuously

**Q3.** Which of the following are *true* statements about SSM Session Manager? (Select all that apply.)
- A) It requires no inbound rules on the instance's security group; the SSM agent maintains an outbound connection to AWS
- B) It logs every session to CloudTrail with the IAM principal who started it
- C) Credentials used by the SSM agent are short-lived, rotating creds derived from the instance profile — no long-lived keys involved
- D) It requires port 22 to be open inbound to the instance

**Q4.** You add a single line to your user data script and run `terraform apply`. Your `aws_instance` resource has `user_data_replace_on_change = true`. What happens to the running instance?
- A) Nothing — user data only runs on first boot, and Terraform's diff engine ignores user data changes by default
- B) Terraform sends the new script to the running instance via SSM, which executes it as root
- C) The instance is terminated and a new one is launched in its place; the new instance boots fresh and executes the updated user data as part of cloud-init's first-boot routine
- D) Terraform errors out because user data changes are non-idempotent

**Q5.** Define the principle of least privilege as it applies to your SandCastle IAM design:
- A) Granting each principal only the permissions strictly required for their current task — for example, the keep's role having only `sts:AssumeRole` for specific per-project roles, rather than account-wide admin access
- B) Restricting AWS Console access to admin users only; CLI access is unrestricted
- C) Using only AWS-managed policies, never inline or customer-managed policies
- D) Granting the maximum permissions a principal might plausibly need over its lifetime, then auditing usage to identify what can be removed

<details>
<summary>Answers</summary>

1. **D** — Network attack surface elimination. The point: zero ingress is *categorically* different from other controls. Encryption (A) protects against a specific exfiltration path, IMDSv2 (B) protects against a specific vulnerability class, CloudTrail (C) is detective-not-preventive. Zero ingress means there's no entry point to defend in the first place — every other control becomes a backup.

2. **B** — Compute is the dominant line. Note A is wrong (Lambda is fractions of a cent here). C invents an EBS-on-stop behavior — EBS keeps billing whether the instance is running or stopped, so auto-stop doesn't help EBS cost. D invents an idle-data-transfer charge.

3. **A, B, C** — All three are core SSM properties. D is the *opposite* of how SSM works: SSM exists specifically to remove the need for port 22.

4. **C** — Instance replacement. Note A is the *default* behavior (which is exactly why `user_data_replace_on_change = true` exists). B invents an SSM-based user-data redelivery mechanism. D is wrong — Terraform applies happily.

5. **A** — Classic least-privilege definition applied to the keep's role design. Note B confuses interface restriction with permission scoping. C overconstrains the principle (managed policies are a tactic, not the principle itself). D is the *opposite* of least privilege — that's "trust then verify" or "audit-driven reduction," which is a different model.

</details>

## Phase 1 Capstone Interview Questions

These are the deeper questions an interviewer might ask after you describe SandCastle. Practice answering each in 2-3 minutes.

1. **"Walk me through SandCastle end to end. What is it, why did you build it, and what did you learn?"**

2. **"What's the most important design decision in SandCastle and why?"**
   *(Hint: SSM-only access is a strong answer. So is the IAM AssumeRole pattern. So is the auto-stop architecture.)*

3. **"How would you scale this if it had to support a team of 5 engineers instead of just you?"**
   *(Hint: separate AWS accounts, AWS SSO, individual IAM roles, instance-per-engineer with shared base AMI, possibly migrating to a tool like Gitpod or Coder for managed orchestration.)*

4. **"What would you change about SandCastle if you had to redo it today?"**
   *(Be honest — interviewers love this question. Maybe ARM. Maybe an EFS mount for `~/dev` so data persists across rebuilds. Maybe a private subnet with a VPC endpoint for SSM to eliminate the public IP entirely.)*

5. **"If a colleague said 'why didn't you just use Lightsail?' how would you respond?"**
   *(Hint: Lightsail is a managed abstraction. SandCastle's value isn't the dev box — it's the practice with VPC, IAM, Terraform, SSM, IaC patterns. Lightsail hides all of that.)*

---

# Phase 1 Complete

You now have a real, working personal development environment on AWS, built entirely with Terraform, with thoughtful security and cost controls in place.

**Next: Phase 2** — Cost engineering. EventBridge schedule + auto-stop Lambda + billing alarms + Cost Anomaly Detection. The piece that takes the monthly bill from ~$37 to ~$10 and gives you the best interview-talking-point in the whole project.

When you're ready for Phase 2, just say the word.
