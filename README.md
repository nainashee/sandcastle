# SandCastle

> A castle in the cloud — my personal development environment on AWS.

[![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform)](https://www.terraform.io/)
[![AWS](https://img.shields.io/badge/Cloud-AWS-FF9900?logo=amazon-aws)](https://aws.amazon.com/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

SandCastle is a personal, cloud-native development environment provisioned entirely as code on AWS. It replaces the need for personal project work to live on a corporate or shared laptop by providing a Linux-based dev box, accessed securely via AWS Systems Manager Session Manager, with automated cost controls that keep it under $20/month.

---

## Table of Contents

- [Why SandCastle Exists](#why-sandcastle-exists)
- [Architecture](#architecture)
- [Key Design Decisions](#key-design-decisions)
- [Project Structure](#project-structure)
- [Getting Started](#getting-started)
- [Cost Analysis](#cost-analysis)
- [Security Posture](#security-posture)
- [Operational Runbook](#operational-runbook)
- [Roadmap](#roadmap)
- [Documentation Index](#documentation-index)

---

## Why SandCastle Exists

I needed a development environment that was:

1. **Separated from my work laptop** — personal AWS credentials, GitHub SSH keys, and side-project code should not live on hardware owned by my employer.
2. **Linux-native** — cloud engineering workflows assume Linux. Developing on Windows/PowerShell creates skill gaps that show up in real engineering work.
3. **Reproducible** — if the instance is lost, corrupted, or I want to rebuild from scratch, it should be a single `terraform apply` away.
4. **Cost-controlled** — running compute 24/7 for personal use is wasteful. The environment should automatically pause when not in use.
5. **A learning artifact** — every component should be intentional, justified, and demonstrate cloud engineering patterns I want to be tested on in interviews.

SandCastle hosts my active personal projects:

- **CloudHunt** — AWS-native job aggregation platform ([nainashee/cloudhunt](https://github.com/nainashee/cloudhunt))
- **PlayHowzat** — cricket trivia game, fully shipped ([nainashee/cricket-zone](https://github.com/nainashee/cricket-zone))
- **hussainashfaque.com** — personal portfolio and blog
- **LaunchPad** — AI-powered job search platform ([nainashee/launchpad](https://github.com/nainashee/launchpad))

---

## Architecture

```
                            ┌─────────────────────────┐
                            │   Hussain's Laptop      │
                            │  (work or personal)     │
                            │   VS Code Remote-SSH    │
                            └───────────┬─────────────┘
                                        │
                                        │ AWS SSM Session Manager
                                        │ (no inbound ports, no SSH keys)
                                        │
                  ┌─────────────────────▼──────────────────────┐
                  │                AWS Cloud                    │
                  │  ┌────────────────────────────────────────┐ │
                  │  │       sandcastle-vpc (10.20.0.0/16)    │ │
                  │  │                                        │ │
                  │  │   ┌──────────────────────────────┐     │ │
                  │  │   │  Public Subnet (us-east-1a)  │     │ │
                  │  │   │                              │     │ │
                  │  │   │   ┌──────────────────────┐   │     │ │
                  │  │   │   │   sandcastle-keep    │   │     │ │
                  │  │   │   │   (EC2 t3.medium)    │   │     │ │
                  │  │   │   │   Amazon Linux 2023  │   │     │ │
                  │  │   │   │   50 GB gp3 EBS      │   │     │ │
                  │  │   │   │   IAM Instance Role  │   │     │ │
                  │  │   │   └──────────────────────┘   │     │ │
                  │  │   │            │                 │     │ │
                  │  │   └────────────┼─────────────────┘     │ │
                  │  │                │                       │ │
                  │  │   Internet Gateway (egress only)       │ │
                  │  └────────────────┼───────────────────────┘ │
                  │                   │                         │
                  │   ┌───────────────▼────────┐                │
                  │   │  EventBridge Schedule  │                │
                  │   │  "the tide" (11 PM PT) │                │
                  │   └──────────┬─────────────┘                │
                  │              │                              │
                  │   ┌──────────▼─────────────┐                │
                  │   │   Auto-Stop Lambda     │                │
                  │   │   (Python 3.12)        │                │
                  │   └────────────────────────┘                │
                  │                                             │
                  │   ┌────────────────────────┐                │
                  │   │  AWS Backup            │                │
                  │   │  Weekly EBS Snapshots  │                │
                  │   └────────────────────────┘                │
                  │                                             │
                  │   ┌────────────────────────┐                │
                  │   │  CloudWatch Alarms     │                │
                  │   │  - Billing > $25/mo    │                │
                  │   │  - Disk > 80%          │                │
                  │   │  - Status check fail   │                │
                  │   └────────────────────────┘                │
                  └─────────────────────────────────────────────┘
```

See [`docs/architecture.md`](docs/architecture.md) for the full architecture write-up including data flows, component responsibilities, and the rendered diagram.

---

## Key Design Decisions

Every significant decision in SandCastle has a rationale. The full set lives in [`docs/design-decisions.md`](docs/design-decisions.md) as Architecture Decision Records (ADRs). Highlights:

| Decision | Choice | Why |
|----------|--------|-----|
| Remote access | SSM Session Manager (not SSH) | No inbound ports, no key rotation, full CloudTrail audit logging |
| Credentials | IAM instance profile (not static keys) | Zero credentials stored on disk; rotated automatically by AWS |
| Instance type | t3.medium | 4 GB RAM handles three projects + dev servers without swap thrash |
| Storage | 50 GB gp3 EBS | gp3 is cheaper than gp2 and tunable; 50 GB leaves headroom for node_modules |
| Cost control | EventBridge + Lambda auto-stop | Reduces compute spend by ~75% with no manual intervention |
| IaC tool | Terraform (not CloudFormation/CDK) | Aligns with what CloudHunt and the broader market use |
| OS | Amazon Linux 2023 | First-party AWS support, SSM agent preinstalled, modern kernel |
| Region | us-east-1 | Lowest cost, matches existing Terraform state buckets, broadest service availability |

---

## Project Structure

```
sandcastle/
├── README.md                    ← you are here
├── LICENSE
├── .gitignore
├── docs/
│   ├── architecture.md          ← architecture deep-dive
│   ├── design-decisions.md      ← ADRs
│   ├── cost-analysis.md         ← cost breakdown & savings math
│   ├── security.md              ← threat model & controls
│   ├── runbook.md               ← day-2 operations
│   └── images/
│       └── architecture.png     ← rendered diagram
├── bootstrap/
│   └── bootstrap-state-backend.sh   ← one-time setup of S3 + DynamoDB for tfstate
├── terraform/
│   ├── backend.tf
│   ├── providers.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── main.tf
│   └── modules/
│       ├── networking/          ← VPC, subnet, IGW, route tables
│       ├── compute/             ← EC2, EBS, user data
│       ├── iam/                 ← instance profile, project role assumption
│       ├── automation/          ← EventBridge schedule + auto-stop Lambda
│       └── observability/       ← CloudWatch alarms, dashboard, log groups
├── scripts/
│   ├── bootstrap-instance.sh    ← user-data script: installs toolchain
│   ├── connect.sh               ← one-liner to SSM-connect into the keep
│   └── snapshot.sh              ← manual EBS snapshot helper
├── lambda/
│   └── auto_stop/
│       ├── handler.py
│       └── requirements.txt
└── LEARNINGS.md                 ← reflection log
```

---

## Getting Started

### Prerequisites

- AWS account (this project uses account `989126024881`)
- AWS CLI v2 configured with admin credentials for initial bootstrap
- Terraform >= 1.6
- An IAM user or role with permissions to create VPC, EC2, IAM, Lambda, EventBridge, and CloudWatch resources

### Deployment

```bash
# 1. Clone the repo
git clone git@github.com:nainashee/sandcastle.git
cd sandcastle

# 2. Bootstrap the Terraform state backend (one-time, manual)
./bootstrap/bootstrap-state-backend.sh

# 3. Initialize Terraform
cd terraform
terraform init

# 4. Review the plan
terraform plan

# 5. Apply
terraform apply
```

Provisioning takes approximately **4 minutes**. On completion, Terraform outputs the instance ID and the SSM connect command.

### First Connection

```bash
# From your laptop (work or personal)
./scripts/connect.sh
```

This opens an SSM Session Manager shell on the keep. From there:

```bash
# Verify the toolchain installed correctly
terraform version
aws --version
node --version
python3 --version
git --version
```

### Migrating Your First Project

```bash
# Example: clone CloudHunt onto SandCastle
cd ~/dev
git clone git@github.com:nainashee/cloudhunt.git
cd cloudhunt/terraform/envs/dev
terraform init   # pulls remote state from the existing jobhunt-terraform-state bucket
terraform plan   # should show "No changes" if migration is clean
```

---

## Cost Analysis

Estimated monthly cost with auto-stop enabled (running ~4 hours/day on weekdays):

| Component | Always-On Cost | With Auto-Stop |
|-----------|---------------:|---------------:|
| EC2 t3.medium compute | $30.37 | $3.40 |
| EBS gp3 50 GB storage | $4.00 | $4.00 |
| Data transfer (estimated) | $0.50 | $0.50 |
| Lambda (auto-stop function) | <$0.01 | <$0.01 |
| CloudWatch (alarms, logs) | $0.30 | $0.30 |
| AWS Backup (4 snapshots) | $1.20 | $1.20 |
| **Total** | **~$36/month** | **~$9.50/month** |

**Savings: ~73%** compared to always-on operation.

The full math, assumptions, and Cost Explorer screenshots are in [`docs/cost-analysis.md`](docs/cost-analysis.md).

---

## Security Posture

SandCastle implements multiple layers of security controls:

- **No inbound network access** — security group has zero ingress rules; access is exclusively via SSM
- **No static credentials on the instance** — IAM instance profile provides temporary, rotating credentials
- **Least-privilege IAM** — the instance profile grants only the permissions required to assume project-specific roles
- **Encryption at rest** — EBS volume encrypted with the AWS-managed KMS key (`alias/aws/ebs`)
- **Encryption in transit** — SSM sessions are TLS-encrypted end-to-end
- **Audit logging** — every SSM session is recorded to CloudWatch Logs and CloudTrail
- **Automated patching** — SSM Patch Manager applies critical updates weekly during a defined maintenance window
- **Backup** — AWS Backup creates encrypted weekly snapshots with 14-day retention

Full threat model and control mapping in [`docs/security.md`](docs/security.md).

---

## Operational Runbook

Common day-2 operations:

| Task | Command / Action |
|------|------------------|
| Connect to the keep | `./scripts/connect.sh` |
| Manually start the instance | `aws ec2 start-instances --instance-ids $(terraform output -raw instance_id)` |
| Manually stop the instance | `aws ec2 stop-instances --instance-ids $(terraform output -raw instance_id)` |
| Take an ad-hoc snapshot | `./scripts/snapshot.sh "pre-upgrade-2026-05-11"` |
| Restore from snapshot | See [`docs/runbook.md#restore-from-snapshot`](docs/runbook.md#restore-from-snapshot) |
| Resize the instance | See [`docs/runbook.md#resize-instance`](docs/runbook.md#resize-instance) |
| Destroy everything | `terraform destroy` (snapshots survive in AWS Backup) |

---

## Roadmap

SandCastle is being built in four phases. Track progress in [GitHub Issues](https://github.com/nainashee/sandcastle/issues).

- [x] **Phase 0** — Project planning and documentation
- [ ] **Phase 1** — Foundation: VPC, EC2, IAM, SSM access, toolchain bootstrap
- [ ] **Phase 2** — Cost engineering: EventBridge auto-stop Lambda, billing alarm
- [ ] **Phase 3** — Observability and resilience: CloudWatch agent, dashboard, AWS Backup
- [ ] **Phase 4** — Polish: architecture diagram, blog post, demo video, README finalization

---

## Documentation Index

| Document | Purpose |
|----------|---------|
| [`docs/architecture.md`](docs/architecture.md) | Full architecture overview with component descriptions and data flows |
| [`docs/design-decisions.md`](docs/design-decisions.md) | Architecture Decision Records (ADRs) — the *why* behind every choice |
| [`docs/cost-analysis.md`](docs/cost-analysis.md) | Detailed monthly cost breakdown, FinOps strategy, and savings math |
| [`docs/security.md`](docs/security.md) | Threat model, security controls, and AWS Well-Architected security pillar mapping |
| [`docs/runbook.md`](docs/runbook.md) | Operational procedures for day-2 tasks, incident response, and disaster recovery |
| [`LEARNINGS.md`](LEARNINGS.md) | Personal reflection log — what worked, what didn't, what I'd change |

---

## License

MIT — see [LICENSE](LICENSE).

## Author

Built by [Hussain Ashfaque](https://hussainashfaque.com) — IT Analyst at UCOP, transitioning into cloud engineering. AWS Certified Solutions Architect – Associate.

GitHub: [@nainashee](https://github.com/nainashee)
