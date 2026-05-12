# SandCastle Phase 1 — Day-by-Day Learning Plan

> Phase 1 goal: Build the foundation. By the end of Day 7 you have a working EC2 dev box on AWS, accessible via SSM, with your full toolchain installed and your first project (CloudHunt) migrated onto it.

## How to Use This Plan

- **Pace yourself**: One day = one session = ~60-90 minutes. Don't rush. The "why" matters more than the "what."
- **Read first, then do**: Each day starts with a "Why we're doing this" section. Read it fully before touching a terminal.
- **Type, don't paste**: When you're learning, typing commands by hand burns them into muscle memory. Copy-paste is fine after you've done a command twice.
- **End-of-day discipline**: Always finish the day's reflection, quiz, and interview questions. This is where the learning compounds. **Skipping these is the difference between "I built a thing" and "I understand a thing."**
- **Stuck for more than 30 minutes?** Stop. Document what you tried in LEARNINGS.md. Move on or ask for help. Getting stuck and not noticing it is the biggest time sink in self-directed learning.

## Phase 1 Overview

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
**Prerequisites**: AWS CLI configured with the `launchpad` profile, Git installed, a GitHub account (`nainashee`)

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
AWS_PROFILE="${AWS_PROFILE:-launchpad}"
PROJECT_NAME="sandcastle"

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
- A) Terraform doesn't support creating S3 buckets
- B) It's a chicken-and-egg problem: the state backend must exist before Terraform can store state in it
- C) AWS doesn't allow Terraform to create state buckets
- D) It would be slower to create it in Terraform

**Q2.** What is the purpose of the DynamoDB table in a Terraform S3 backend?
- A) Storing the actual Terraform state
- B) Caching plan output for faster applies
- C) State locking — preventing concurrent applies from corrupting state
- D) Storing AWS credentials

**Q3.** Why is S3 versioning critical for a Terraform state bucket?
- A) It's required by AWS
- B) It allows rolling back if state is corrupted or accidentally overwritten
- C) It encrypts the state
- D) It improves performance

**Q4.** Which S3 setting prevents a state file from being accidentally exposed to the internet?
- A) Bucket encryption
- B) Versioning
- C) Block public access (all four sub-settings)
- D) Tagging

**Q5.** Why use `PAY_PER_REQUEST` billing mode for the lock table instead of provisioned capacity?
- A) It's the only mode that supports locks
- B) Lock operations are infrequent; provisioned capacity would be wasteful
- C) Pay-per-request is always cheaper
- D) It enables encryption

<details>
<summary>Answers</summary>

1. **B** — The state backend must exist before Terraform initializes against it. This is why a one-time bootstrap script is the standard pattern.
2. **C** — DynamoDB stores a lock record while a `terraform apply` is in progress. Other applies see the lock and wait or error out.
3. **B** — Versioning is your safety net. State corruption is real (it has happened in production at most companies that use Terraform). Versioning lets you restore yesterday's state in seconds.
4. **C** — All four block public access settings working together is what prevents misconfiguration from leaking state. Encryption (A) protects content; public access blocking protects exposure.
5. **B** — Lock table activity is sporadic — a few writes per `terraform apply`. Pay-per-request has no minimum cost and scales to zero. Provisioned capacity (10 RCU/WCU) would cost a few dollars/month for no benefit.

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
  description = "AWS CLI profile to use"
  type        = string
  default     = "launchpad"
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

**Q1.** Why does the `sandcastle-keep-sg` security group have zero inbound rules?
- A) It's a Terraform default
- B) Access is via SSM Session Manager, which uses outbound-initiated connections only
- C) Inbound rules cost extra
- D) AWS doesn't allow inbound rules in public subnets

**Q2.** What does `map_public_ip_on_launch = true` do on a subnet?
- A) Forces all instances to use Elastic IPs
- B) Automatically assigns a public IP to instances launched in this subnet
- C) Maps the subnet to a public DNS name
- D) Enables the internet gateway

**Q3.** Why does the route table need a `0.0.0.0/0` route to the internet gateway?
- A) Without it, instances can't reach the internet for package installs, GitHub, etc.
- B) It's required for the VPC to function
- C) It's only needed for inbound traffic
- D) It enables SSM

**Q4.** What is the purpose of `default_tags` in the AWS provider block?
- A) It tags only the provider itself
- B) Every resource managed by this provider gets these tags automatically, preventing missed tags
- C) It sets default values for resource arguments
- D) It applies tags only at first apply

**Q5.** Why is `enable_dns_hostnames = true` set on the VPC?
- A) It's required by Terraform
- B) It allows instances to resolve internal AWS service endpoints by hostname (e.g., SSM endpoints)
- C) It enables Route 53
- D) It allows external DNS resolution

<details>
<summary>Answers</summary>

1. **B** — SSM uses an outbound HTTPS connection from the SSM agent on the instance to the SSM service. No inbound port is required. This is the whole point.
2. **B** — Public subnets need this for instances to get a public IP. Without it, you'd have to allocate Elastic IPs manually.
3. **A** — The route table tells the VPC how to route traffic. Without a default route, traffic destined outside the VPC has nowhere to go.
4. **B** — Default tags are applied at the provider level. Every resource gets them. Critical for consistent tagging and cost allocation.
5. **B** — DNS hostnames are required for AWS service endpoints (SSM, S3, etc.) to resolve correctly inside the VPC. Without this, SSM agent registration fails.

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

**Q1.** What is the difference between an IAM role and an IAM instance profile?
- A) They are the same thing
- B) A role defines permissions; an instance profile is a container that allows an EC2 instance to use the role
- C) A role is for users; an instance profile is for services
- D) Instance profiles have more permissions than roles

**Q2.** Why use `sts:AssumeRole` for cross-project access instead of attaching all project permissions directly to the keep's role?
- A) AssumeRole is faster
- B) It enforces least privilege: each project's permissions are isolated, and credentials are short-lived
- C) It's required by AWS
- D) Direct attachment doesn't work across projects

**Q3.** What does the trust policy on `sandcastle-keep-role` define?
- A) What the role can do
- B) Who can assume the role (in this case, the EC2 service)
- C) When the role expires
- D) Which region the role works in

**Q4.** Why prefer AWS-managed policies (like `AmazonSSMManagedInstanceCore`) over writing your own equivalent?
- A) They're free; custom policies cost money
- B) AWS maintains them — as the service evolves, your permissions stay correct
- C) Custom policies don't work with EC2
- D) Managed policies are always smaller

**Q5.** If an attacker gained shell access to the keep but the IAM role only had `AssumeRole` permissions for `cloudhunt-dev`, what would they NOT be able to do?
- A) Read instance metadata
- B) Make API calls outside of CloudHunt's allowed actions
- C) Run shell commands on the instance
- D) Access the local filesystem

<details>
<summary>Answers</summary>

1. **B** — A role is the permission set; an instance profile is the EC2-specific wrapper that attaches the role to an instance. You can't attach a role directly to EC2 without an instance profile.
2. **B** — Role assumption produces short-lived (typically 1-hour) credentials and enforces explicit scope per project. Direct attachment would be permanent and over-privileged.
3. **B** — Trust policies define *who* can assume a role. The permissions policy defines *what* the role can do.
4. **B** — When SSM adds a new feature, AWS updates the managed policy. A custom policy you wrote a year ago wouldn't get the update.
5. **B** — The attacker can do anything inside the OS (the role doesn't gate shell access), but their AWS API access is limited to assuming `cloudhunt-dev` and whatever that role permits — not the whole account.

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
  --profile launchpad
```

You should see your instance with `"PingStatus": "Online"`. If not, wait another 30 seconds and retry.

Now connect:

```bash
aws ssm start-session --target $(terraform output -raw instance_id) --profile launchpad
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

AWS_PROFILE="${AWS_PROFILE:-launchpad}"

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

**Q1.** Why use the SSM Parameter Store to resolve the AMI ID instead of hardcoding it?
- A) Hardcoded AMI IDs go stale (AWS releases new versions weekly); SSM resolves to the latest automatically
- B) SSM is faster
- C) Hardcoded AMIs cost more
- D) AWS doesn't allow hardcoded AMI IDs

**Q2.** What does `http_tokens = "required"` do?
- A) Requires HTTPS for all metadata requests
- B) Enforces IMDSv2 — token-based metadata access only, blocking IMDSv1 SSRF attacks
- C) Encrypts the metadata
- D) Disables the metadata service

**Q3.** Why does the security group have no inbound rules, yet you can still connect to the instance?
- A) SSM agent on the instance opens an outbound connection to the SSM service; your "session" is proxied through AWS
- B) The default rule allows your IP
- C) SSM requires no security group
- D) Public IPs bypass security groups

**Q4.** Why is the `ignore_changes = [ami]` lifecycle rule on the instance important?
- A) Without it, every time AWS publishes a new AL2023 AMI, Terraform would want to recreate the instance — wiping the disk
- B) It speeds up Terraform
- C) It's required for SSM
- D) It prevents tagging changes

**Q5.** What happens to the EBS volume when the instance is stopped?
- A) It's deleted
- B) It persists; data is preserved
- C) It's snapshotted
- D) It's detached

<details>
<summary>Answers</summary>

1. **A** — AMI IDs change frequently as AWS publishes security patches. The SSM Parameter pattern is the industry-standard way to always get the current image.
2. **B** — IMDSv2 requires a session token (obtained via PUT, which SSRF can't forge), making credential theft via metadata-service exploits much harder.
3. **A** — SSM Session Manager works through outbound-initiated WebSocket connections from the SSM agent. No inbound port needed.
4. **A** — Without `ignore_changes`, every AMI update Terraform sees would trigger an instance replacement, destroying the EBS volume in the process. This is one of the most common production-disaster patterns in Terraform.
5. **B** — EBS volumes are durable and independent of instance state. Stopping the instance doesn't affect the disk; only terminating with `delete_on_termination=true` removes it.

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

**Q1.** When does EC2 user data run by default?
- A) On every boot
- B) Only on the first boot of an instance
- C) When the user runs it manually
- D) When the SSM agent triggers it

**Q2.** Why does the bootstrap script run as root?
- A) User data always runs as root by default
- B) Only root can install system packages
- C) Both A and B
- D) Neither

**Q3.** What's the purpose of `user_data_replace_on_change = true`?
- A) Reruns user data on the existing instance
- B) Replaces the instance when user data changes, so the new script actually runs
- C) Makes user data optional
- D) Improves performance

**Q4.** Why is idempotency important in a bootstrap script?
- A) AWS requires it
- B) So the script can be safely re-run without breaking or duplicating installs
- C) It's faster
- D) It enables logging

**Q5.** What's the purpose of the `/var/log/sandcastle-bootstrap.complete` marker file?
- A) Required by cloud-init
- B) Gives you a quick way to verify the bootstrap finished successfully without parsing log files
- C) Triggers a CloudWatch alarm
- D) Required by SSM

<details>
<summary>Answers</summary>

1. **C** — User data runs once on first boot. Subsequent boots don't re-run it unless explicitly configured. This is a deliberate design choice — re-running install scripts on every boot would be slow and risky.
2. **C** — Both. Cloud-init runs user data as root by default, and installing system packages requires root.
3. **B** — User data only takes effect on first boot. If you change the script but don't replace the instance, the change does nothing. This flag enforces "user data is part of the instance's identity."
4. **B** — During development you'll re-run the script while debugging. Idempotent guards (`if ! command -v ...`) make this safe.
5. **B** — When something goes wrong, you want a quick boolean answer to "did the bootstrap finish?" The marker file gives you that without scrolling through hundreds of log lines.

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

[profile launchpad]
region = us-east-1
credential_source = Ec2InstanceMetadata
EOF
```

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

**Q1.** Why generate a *new* SSH key on the keep instead of copying your laptop's key?
- A) Faster
- B) The key on the keep can be revoked independently if the keep is compromised, without affecting your laptop
- C) AWS requires it
- D) SSH keys can't be transferred

**Q2.** What does `credential_source = Ec2InstanceMetadata` in `~/.aws/config` do?
- A) Reads credentials from a file
- B) Tells the AWS SDK to fetch credentials from the EC2 instance metadata service
- C) Disables credentials
- D) Encrypts credentials

**Q3.** Why does VS Code Remote-Tunnels work even with no inbound ports open on the keep?
- A) It uses a magic AWS feature
- B) The tunnel is outbound-initiated; the keep connects to Microsoft's tunnel service, your laptop connects to the same service
- C) It bypasses security groups
- D) Tunnels require port 443 to be open

**Q4.** What's the risk of putting static AWS access keys on the keep instead of using the instance profile?
- A) No risk
- B) If the keep is compromised or snapshotted, those keys leak; rotating them is manual
- C) Static keys are faster
- D) Static keys don't work on EC2

**Q5.** Why is `pre-commit install` important for the cloned CloudHunt repo?
- A) It's not — pre-commit is optional
- B) It re-installs the git hooks locally so the project's quality checks run on every commit
- C) It downloads dependencies
- D) It re-initializes Terraform

<details>
<summary>Answers</summary>

1. **B** — Defense in depth. Independent keys mean a compromise of one machine doesn't compromise GitHub access from other machines.
2. **B** — This tells the SDK to use IMDS for credentials, which gets short-lived, rotating creds from the instance profile.
3. **B** — Outbound-initiated rendezvous through a third-party service. Same pattern as SSM, ngrok, Tailscale, etc.
4. **B** — Static keys at rest are a leak waiting to happen. Instance profile creds rotate automatically and exist only in memory.
5. **B** — Pre-commit hooks are stored per-checkout (in `.git/hooks/`), not in the repo. Cloning gets the *config* but not the installed hooks. `pre-commit install` activates them.

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
  --profile launchpad \
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
  value       = "aws ssm start-session --target ${module.compute.instance_id} --profile launchpad"
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
  --profile launchpad
```

You should see daily costs around $1 (since you've been running 24/7 during the build). This confirms cost allocation tagging is working.

## Step 7: Set up your daily workflow alias (5 min)

On your laptop, add this to `~/.bashrc` or `~/.zshrc`:

```bash
alias castle='cd ~/dev/sandcastle && ./scripts/connect.sh'
alias castle-up='aws ec2 start-instances --instance-ids $(terraform -chdir=$HOME/dev/sandcastle/terraform output -raw instance_id) --profile launchpad'
alias castle-down='aws ec2 stop-instances --instance-ids $(terraform -chdir=$HOME/dev/sandcastle/terraform output -raw instance_id) --profile launchpad'
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

**Q1.** What is the single most important security control in SandCastle's design?
- A) Encrypted EBS volumes
- B) IMDSv2 enforcement
- C) Zero inbound rules on the security group (combined with SSM access)
- D) CloudTrail logging

**Q2.** Why is the auto-stop Lambda (Phase 2) the single biggest cost driver?
- A) Lambda is expensive
- B) It reduces EC2 compute hours by ~75%, the dominant cost line
- C) It eliminates EBS cost
- D) It eliminates data transfer cost

**Q3.** Which of these are true of using SSM Session Manager? (Multiple correct.)
- A) Requires no inbound security group rules
- B) Provides full audit logging to CloudTrail
- C) Uses temporary credentials, not long-lived keys
- D) Requires port 22 open

**Q4.** When you change the user data script and `terraform apply`, what happens?
- A) Nothing (user data only runs on first boot)
- B) The script re-runs on the existing instance
- C) Terraform replaces the instance (because `user_data_replace_on_change = true`)
- D) Terraform errors out

**Q5.** What is the principle of least privilege?
- A) Granting users the maximum permissions they might ever need
- B) Granting users only the permissions required for their current task, and no more
- C) Restricting access to admin users only
- D) Using only AWS-managed policies

<details>
<summary>Answers</summary>

1. **C** — Zero ingress means there's nothing to attack on the network surface. Every other control is defense in depth.
2. **B** — EC2 compute is ~80% of the bill at always-on. Cutting hours by 75% drops the dominant line.
3. **A, B, C** — All three are core SSM benefits. D is the *opposite* of what SSM enables.
4. **C** — With `user_data_replace_on_change = true`, Terraform replaces the instance. Otherwise (default behavior) the user data change is ignored.
5. **B** — Classic security principle. The opposite (A) is the most common cause of catastrophic IAM-related breaches.

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
