# Architecture

This document describes the SandCastle architecture in depth: components, data flows, network topology, and how the pieces fit together.

## Overview

SandCastle is a single-region, single-AZ AWS deployment optimized for cost and simplicity rather than high availability. It is a personal development environment, not a production system — the trade-offs reflect that.

The architecture is composed of five logical layers:

1. **Networking** — VPC, subnet, internet gateway, route tables
2. **Compute** — EC2 instance ("the keep"), EBS volume, user-data bootstrap
3. **Identity** — IAM instance profile, role assumption for cross-project access
4. **Automation** — EventBridge schedule, auto-stop Lambda, AWS Backup
5. **Observability** — CloudWatch alarms, dashboard, log groups, CloudTrail

---

## Network Topology

### VPC Design

- **CIDR**: `10.20.0.0/16`
- **Region**: `us-east-1`
- **Availability Zones**: `us-east-1a` only (single-AZ by design)

Single-AZ is a deliberate choice. SandCastle is not production infrastructure — there is no SLA, no users, no business continuity requirement. Adding a second AZ doubles NAT gateway costs (if I added private subnets) and provides no real benefit for a personal dev environment. If the AZ goes down, I work on my laptop for a few hours.

### Subnets

| Name | CIDR | Type | Purpose |
|------|------|------|---------|
| `sandcastle-public-1a` | `10.20.1.0/24` | Public | Hosts the keep |

The keep lives in a public subnet despite having no inbound rules. This is a cost optimization — a private subnet would require a NAT Gateway (~$33/month) for the instance to reach the internet for `apt`, `yum`, GitHub, npm, pip, etc. Since the security group blocks all inbound traffic and access is via SSM (which uses outbound HTTPS to AWS endpoints, not inbound SSH), the public subnet is safe.

### Security Group

The `sandcastle-keep-sg` security group has:

- **Inbound rules**: NONE. Zero. Not even SSH.
- **Outbound rules**: All traffic to 0.0.0.0/0 (required for SSM agent to reach AWS endpoints, package managers, GitHub, etc.)

This is the single most important security property of the design. With no inbound rules, the keep cannot be directly attacked from the internet. There is no SSH port to brute-force, no exposed service to exploit. All access must go through AWS IAM and SSM.

### Internet Gateway and Routing

- Standard internet gateway attached to the VPC
- Public subnet route table has a default route (`0.0.0.0/0`) to the IGW
- The instance receives a public IP for outbound internet access only (security group prevents inbound)

---

## Compute

### The Keep (EC2 Instance)

| Property | Value |
|----------|-------|
| Name tag | `sandcastle-keep` |
| Instance type | `t3.medium` (2 vCPU, 4 GB RAM) |
| AMI | Latest Amazon Linux 2023 (resolved via SSM Parameter Store) |
| Root volume | 50 GB gp3, encrypted with `alias/aws/ebs` |
| IMDSv2 | Required (token-only, no IMDSv1 fallback) |
| Detailed monitoring | Disabled (saves $2.10/month, default 5-min metrics are sufficient) |
| Termination protection | Disabled (this is intentional — I want `terraform destroy` to work) |

### AMI Selection

The AMI ID is resolved dynamically via the SSM Parameter Store path:

```
/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
```

This avoids hardcoding AMI IDs in Terraform (which would go stale) and ensures every rebuild gets the most current Amazon Linux 2023 image, including security patches.

### User Data Bootstrap

On first boot, the instance runs `scripts/bootstrap-instance.sh` via EC2 user data. This script:

1. Updates all system packages
2. Installs developer tooling: `git`, `tmux`, `jq`, `unzip`, `python3.12`, `python3-pip`, `docker`
3. Installs Node.js 20 via NodeSource repository
4. Installs Terraform via HashiCorp's official YUM repository
5. Installs AWS CLI v2 from the official installer
6. Installs the CloudWatch agent
7. Installs `pre-commit` via pip
8. Creates a non-root user `hussain` with sudo privileges
9. Configures `~/.ssh/known_hosts` to trust `github.com`
10. Sets up tmux config and shell aliases
11. Writes a marker file `/var/log/sandcastle-bootstrap.complete` for verification

Total bootstrap time: ~3 minutes.

### Storage

The root EBS volume is `gp3`, sized at 50 GB. Why these choices:

- **gp3 over gp2**: gp3 is roughly 20% cheaper per GB and lets you tune IOPS and throughput independently of size. For development workloads, the default 3,000 IOPS / 125 MB/s is plenty.
- **50 GB over 30 GB**: Three project repositories with their `node_modules`, `.terraform` plugin caches, Docker images, and build artifacts add up fast. Running out of disk on a dev box is one of the most frustrating failure modes possible.
- **Encryption**: All EBS volumes are encrypted using the AWS-managed key. There's no additional cost and it's a default control I shouldn't skip even for a personal environment.

---

## Identity and Access Management

### Instance Profile

The keep has an attached IAM instance profile (`sandcastle-keep-instance-profile`) that wraps an IAM role (`sandcastle-keep-role`). This role has the following managed policies attached:

- `AmazonSSMManagedInstanceCore` — required for SSM Session Manager
- `CloudWatchAgentServerPolicy` — allows the CloudWatch agent to publish metrics

It also has a custom inline policy that grants:

- `sts:AssumeRole` on a set of project-specific roles (`cloudhunt-dev`, `cricket-zone-dev`, `launchpad-dev`)
- `ec2:DescribeInstances` and `ec2:DescribeTags` (so scripts on the instance can self-identify)

### Role Assumption Pattern

Rather than storing static AWS access keys on the instance (a credential-leak risk), each project has a dedicated IAM role that the instance profile is allowed to assume. The `~/.aws/config` file on the keep is configured like:

```ini
[profile cloudhunt]
role_arn = arn:aws:iam::989126024881:role/cloudhunt-dev
credential_source = Ec2InstanceMetadata
region = us-east-1

[profile cricket-zone]
role_arn = arn:aws:iam::989126024881:role/cricket-zone-dev
credential_source = Ec2InstanceMetadata
region = us-east-1
```

When I run `terraform apply` in CloudHunt, the AWS SDK automatically assumes the `cloudhunt-dev` role and uses short-lived credentials. Nothing sensitive is ever written to disk.

This pattern is the same one used in well-run multi-account or multi-team AWS environments. It scales naturally if I ever migrate to a multi-account setup.

---

## Automation

### Auto-Stop ("the tide")

A scheduled EventBridge rule fires every weeknight at 11:00 PM Pacific Time (06:00 UTC). The rule targets a Lambda function (`sandcastle-auto-stop`) that:

1. Queries EC2 for instances tagged `AutoStop=true`
2. Filters to instances in `running` state
3. Calls `StopInstances` on the matching set
4. Publishes a custom CloudWatch metric `SandCastle/AutoStop/InstancesStopped`
5. Logs the action to CloudWatch Logs

The Lambda is intentionally tag-driven rather than hardcoded to a single instance ID. This means the same Lambda can manage multiple dev boxes if I add more in the future, just by tagging them appropriately.

There is **no auto-start counterpart**. Manual start is a deliberate choice — it forces me to be intentional about when I'm working, and saves money by ensuring the instance isn't running on days I don't open it.

### Backup

AWS Backup runs a daily plan named `sandcastle-backup-plan` with the following rules:

- **Schedule**: Daily at 05:00 UTC
- **Target**: All resources tagged `Project=sandcastle` and `BackupPolicy=daily`
- **Retention**: 14 days
- **Vault**: `sandcastle-backup-vault` (encrypted with the AWS-managed key)

Recovery point objective (RPO): 24 hours.
Recovery time objective (RTO): ~30 minutes (time to provision a new EBS volume from snapshot and attach it).

---

## Observability

### CloudWatch Alarms

| Alarm | Threshold | Action |
|-------|-----------|--------|
| `sandcastle-billing-alarm` | Estimated monthly charges > $25 | Email notification via SNS |
| `sandcastle-disk-usage` | Root volume > 80% used | Email notification |
| `sandcastle-status-check-failed` | Instance status check failed for 2 consecutive periods | Email notification |
| `sandcastle-cpu-credit-balance` | T3 CPU credit balance < 30 | Email notification (signals undersized instance) |

All alarms publish to a single SNS topic `sandcastle-alerts` subscribed to my personal email.

### CloudWatch Dashboard

A dashboard named `sandcastle-overview` displays:

- CPU utilization (line chart, 1-hour window)
- Memory utilization (custom metric from CloudWatch agent)
- Disk usage (custom metric from CloudWatch agent)
- Network in/out (bytes)
- Status check pass/fail
- Auto-stop event count (last 30 days)

### CloudTrail

A trail named `sandcastle-trail` records all management events in the account to an S3 bucket. SSM session start/end events are visible here, which provides a complete audit log of every interactive session on the keep.

---

## Data Flows

### Interactive Session Flow

```
Hussain's laptop
  → AWS CLI / VS Code Remote-SSH (over SSM)
  → SSM service (regional endpoint, TLS)
  → SSM agent on the keep (outbound-initiated connection)
  → bash shell on the keep
```

No inbound network connection is made to the keep at any point in this flow.

### Project Deployment Flow (example: CloudHunt)

```
On the keep:
  cd ~/dev/cloudhunt/terraform/envs/dev
  terraform apply
    → Terraform reads state from S3 (jobhunt-terraform-state-989126024881)
    → AWS SDK assumes cloudhunt-dev role via instance metadata
    → Plan/apply against AWS APIs using short-lived credentials
```

### Auto-Stop Flow

```
EventBridge rule (cron: 0 6 * * 2-6)
  → Lambda: sandcastle-auto-stop
  → EC2 DescribeInstances (filter: tag:AutoStop=true)
  → EC2 StopInstances (matching IDs)
  → CloudWatch PutMetricData
  → CloudWatch Logs (function output)
```

---

## What's Intentionally Missing

A note on what SandCastle deliberately does *not* include, and why:

- **High availability** — single AZ, single instance. Personal dev environment; HA would be cost theater.
- **A NAT Gateway** — too expensive ($33/month) for the use case. Public subnet with restrictive SG provides equivalent isolation.
- **Auto-scaling** — meaningless for a single dev box.
- **A bastion host** — SSM replaces the need entirely. A bastion would be a regression to the SSH-key-management problem SSM solves.
- **VPN / Direct Connect** — overkill for a one-person environment.
- **Multi-account separation** — would be ideal for true production/dev isolation but adds complexity that doesn't pay off at this scale. May revisit in a future phase.

---

## Well-Architected Framework Alignment

SandCastle is reviewed against the six pillars of the AWS Well-Architected Framework. Full mapping in [`design-decisions.md`](design-decisions.md) and [`security.md`](security.md).

| Pillar | Summary |
|--------|---------|
| Operational Excellence | IaC, runbooks, tagged resources, automated bootstrap |
| Security | No inbound access, IAM instance profile, encryption at rest and in transit, full audit logging |
| Reliability | Daily snapshots via AWS Backup, status check alarms, documented restore procedure |
| Performance Efficiency | Right-sized instance, gp3 storage, ARM consideration deferred (see ADR-007) |
| Cost Optimization | Auto-stop, billing alarm, gp3 over gp2, single-AZ, no NAT Gateway |
| Sustainability | Auto-stop reduces compute hours by ~75%, minimizing carbon footprint of personal dev work |
