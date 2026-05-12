# Architecture Decision Records (ADRs)

This document captures every significant architectural decision in SandCastle along with the context, alternatives considered, and consequences. Each ADR follows a lightweight version of the [Michael Nygard format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).

ADRs are immutable once accepted. If a decision is reversed, a new ADR is added that supersedes the old one.

---

## ADR-001: Use AWS as the Cloud Provider

**Status**: Accepted
**Date**: 2026-05-11

### Context

I need a cloud platform to host my personal development environment and projects. The major options are AWS, Azure, and Google Cloud.

### Decision

Use AWS.

### Rationale

- I hold the AWS Solutions Architect – Associate certification; deepening AWS expertise compounds career value
- All existing projects (CloudHunt, PlayHowzat, LaunchPad) are already on AWS
- AWS has the largest job market for cloud engineering roles, particularly in government/public sector which I'm targeting
- The existing Terraform state buckets and IAM users are in AWS account 989126024881; consolidating reduces operational overhead

### Consequences

- Skill development is concentrated in AWS — less breadth across providers
- Vendor lock-in via managed services (acceptable trade-off for personal use)

---

## ADR-002: Use SSM Session Manager Instead of SSH

**Status**: Accepted
**Date**: 2026-05-11

### Context

I need a secure way to access the keep from my laptop. The traditional choice is SSH with a keypair; the modern AWS-native choice is Systems Manager Session Manager.

### Decision

Use SSM Session Manager exclusively. No SSH access. No port 22 open in the security group.

### Alternatives Considered

1. **SSH with keypair** — Standard, well-understood, works with every tool. But requires managing keys, rotating them, and exposing port 22 (even if IP-restricted).
2. **EC2 Instance Connect** — AWS's "SSH but managed" service. Still requires inbound SSH access; only the key delivery is managed.
3. **SSM Session Manager** — No inbound port required, no keys to manage, full audit logging in CloudTrail, IAM-based authentication.

### Rationale

- **No attack surface**: With zero inbound rules, the keep cannot be directly attacked from the internet. There is no SSH service to brute-force.
- **No key management**: Personal SSH keys are a recurring source of leaks (committed to repos, left on lost laptops, etc.). SSM uses temporary IAM credentials.
- **Audit trail**: Every session is logged to CloudTrail with the IAM principal who connected, when, and (optionally) the commands run.
- **Industry direction**: Well-run AWS shops are migrating away from SSH-on-bastion to SSM. This is a "future-proof" choice.
- **Interview value**: This is exactly the kind of detail that distinguishes a thoughtful cloud engineer from someone who followed a tutorial.

### Consequences

- Slightly higher learning curve initially (`aws ssm start-session` vs `ssh user@host`)
- VS Code Remote-SSH requires a small configuration tweak to tunnel through SSM
- SCP-style file transfer is more awkward; mitigated by using `git` as the primary file transport
- Dependent on AWS SSM service availability (single point of failure for access)

---

## ADR-003: Use IAM Instance Profile, Never Static Access Keys on the Instance

**Status**: Accepted
**Date**: 2026-05-11

### Context

The keep needs AWS credentials to manage resources for CloudHunt, PlayHowzat, and other projects. There are two general approaches: install long-lived access keys via `aws configure`, or use an IAM instance profile that provides temporary credentials via instance metadata.

### Decision

Use an IAM instance profile attached to the keep. Never run `aws configure` with static keys. Project-specific access is granted via IAM role assumption from the instance profile.

### Rationale

- **No credentials at rest**: Static keys in `~/.aws/credentials` are a credential-leak risk if the EBS volume is ever snapshotted, the AMI shared, or the instance compromised.
- **Automatic rotation**: Instance metadata credentials rotate automatically every few hours. Static keys don't rotate unless I remember to do it.
- **Least privilege via role assumption**: Each project (CloudHunt, PlayHowzat, etc.) has its own IAM role with scoped permissions. The instance profile only has permission to *assume* those roles, not the underlying permissions directly.
- **Auditable**: CloudTrail records every `sts:AssumeRole` call, making it clear which session did what.

### Consequences

- Requires creating one IAM role per project (slight upfront cost)
- AWS CLI configuration uses `credential_source = Ec2InstanceMetadata`, which is slightly less common than profile-based config
- Requires IMDSv2 to be enforced to prevent SSRF-style attacks on the metadata service

---

## ADR-004: Instance Type t3.medium

**Status**: Accepted
**Date**: 2026-05-11

### Context

The keep needs to run Terraform plans, Node/Python builds, the AWS CLI, occasional Docker containers, and serve as a VS Code Remote-SSH target — potentially for multiple projects at once.

### Decision

Use `t3.medium` (2 vCPU, 4 GB RAM) as the initial instance type.

### Alternatives Considered

| Type | vCPU | RAM | $/mo (24/7) | Verdict |
|------|------|-----|-------------|---------|
| t3.micro | 2 | 1 GB | $7.50 | Too small; constant swap |
| t3.small | 2 | 2 GB | $15 | Workable for one project, tight for three |
| **t3.medium** | **2** | **4 GB** | **$30** | **Sweet spot** |
| t3.large | 2 | 8 GB | $60 | Overkill for current workload |
| t4g.medium (ARM) | 2 | 4 GB | $24 | Cheaper, but ARM compatibility risk for some tools |

### Rationale

- 4 GB RAM is the minimum comfortable size for running VS Code Remote-SSH + a dev server + a build process without thrashing
- Burstable T-series matches the bursty nature of dev work (idle for minutes, then a build spike)
- x86 chosen over ARM (t4g) to avoid edge cases with Node native modules, Python packages, and Docker images that aren't ARM-ready
- Auto-stop reduces effective monthly cost to ~$3.40, making the choice essentially free compared to t3.small

### Consequences

- ~$15/month more than t3.small in 24/7 cost; ~$2/month more with auto-stop (negligible)
- Resize is trivial if needs change (`stop → modify instance type → start`, ~2 min downtime)

### Revisit Triggers

- If CPU credit balance alarm fires consistently → upsize to m6i.large or consider ARM (t4g.medium)
- If RAM utilization stays below 30% for 30 days → downsize to t3.small

---

## ADR-005: gp3 EBS Storage, 50 GB

**Status**: Accepted
**Date**: 2026-05-11

### Context

The root volume needs to hold the OS, developer tooling, multiple project repositories, `node_modules`, Docker images, build artifacts, and personal config. Volume type and size both affect cost and performance.

### Decision

Use a 50 GB `gp3` volume, encrypted with the AWS-managed KMS key.

### Rationale

- **gp3 over gp2**: gp3 is ~20% cheaper per GB and decouples IOPS/throughput from volume size. gp2's price-per-GB is higher and its performance scales with size, leading to over-provisioning for performance reasons alone.
- **50 GB over 30 GB**: A single React project's `node_modules` can be 1 GB. With three projects, plus Docker images, plus Terraform plugin caches, plus build artifacts, 30 GB fills up faster than expected. Running out of disk in the middle of work is one of the most disruptive failure modes possible, and the cost difference is ~$1.60/month.
- **Encryption**: Default control. Zero cost. No reason to skip it.

### Consequences

- ~$4/month storage cost (vs ~$2.40 for 30 GB gp2)
- Encryption adds no measurable performance overhead

---

## ADR-006: Single Availability Zone

**Status**: Accepted
**Date**: 2026-05-11

### Context

AWS recommends multi-AZ deployments for production workloads. Multi-AZ provides resilience against single-AZ failures but adds complexity and (depending on services used) cost.

### Decision

Deploy SandCastle in a single AZ (`us-east-1a`).

### Rationale

- SandCastle is a personal dev environment, not a production system. There is no SLA, no users, no business continuity requirement.
- A multi-AZ deployment would require either: (a) a second instance in another AZ (doubles compute cost), or (b) the ability to fail over via snapshot/AMI (slow, manual, not actually HA).
- Single-AZ failures in AWS are rare (sub-1%/year per AZ historically). The expected downtime is negligible.
- Cost matters more than uptime for this use case.

### Consequences

- ~99% effective availability is acceptable
- If AZ fails, I work on my laptop for a few hours until it recovers
- The architecture is simpler, which is itself a benefit

---

## ADR-007: Defer ARM (Graviton) Adoption

**Status**: Accepted
**Date**: 2026-05-11

### Context

AWS Graviton (ARM) instances are 20% cheaper than equivalent x86 instances. `t4g.medium` would save ~$6/month compared to `t3.medium`.

### Decision

Use x86 (`t3.medium`) for now. Revisit ARM in Phase 4 or later.

### Rationale

- Some Node native modules, Python C extensions, and Docker images are not ARM-ready
- Diagnosing "this works on my old box but not the new ARM one" wastes time I'd rather spend on actual project work
- The savings ($6/month or ~$1.50/month with auto-stop) are real but not life-changing
- ARM adoption is a future ADR worth writing intentionally rather than a default choice

### Consequences

- ~$6/month opportunity cost (or ~$1.50 with auto-stop)
- All dev tools are x86-compatible without thinking

### Revisit Triggers

- All my project Docker images publish multi-arch manifests → switch to t4g.medium
- I want a portfolio talking point about ARM migration → write ADR-007a documenting the migration

---

## ADR-008: Public Subnet Without NAT Gateway

**Status**: Accepted
**Date**: 2026-05-11

### Context

The instance needs outbound internet access for package managers, GitHub, and AWS service endpoints. There are two standard patterns: place it in a public subnet with a direct IGW route, or place it in a private subnet with a NAT Gateway for egress.

### Decision

Place the keep in a public subnet with a direct route to the internet gateway. No NAT Gateway.

### Rationale

- A NAT Gateway costs ~$33/month plus data processing fees. For a single dev instance, this nearly doubles the cost of the environment.
- The security risk of being in a public subnet is mitigated entirely by the security group having zero inbound rules.
- The keep's "public" IP is, in practice, never used inbound — the SG blocks everything.

### Consequences

- The instance has a public IP, which feels less secure superficially but is functionally equivalent to a private IP given the SG configuration
- If I ever need to share the architecture with someone familiar only with the "private subnet + NAT" pattern, I have to explain this choice
- Saves ~$33/month vs the textbook pattern

---

## ADR-009: Auto-Stop Without Auto-Start

**Status**: Accepted
**Date**: 2026-05-11

### Context

To reduce compute cost, the instance should be stopped when not in use. This can be implemented as auto-stop only, or as auto-stop + auto-start (e.g., "always start at 8 AM").

### Decision

Implement auto-stop only. The instance must be manually started when I want to use it.

### Rationale

- **Cost discipline**: Manual start ensures the instance isn't running on days I don't actually work on personal projects. On a vacation week, the instance stays off entirely.
- **Simplicity**: Auto-start logic has more edge cases (DST, holidays, sick days) and provides little value if I'm already at my laptop ready to work.
- **Habit-forming**: Manually starting the instance is a small friction that signals "I am about to do focused work."

### Consequences

- Mild inconvenience: an extra 30-second `aws ec2 start-instances` step before working
- Mitigated by a shell alias on my laptop: `alias castle-up='aws ec2 start-instances --instance-ids i-xxx && aws ec2 wait instance-status-ok ...'`

---

## ADR-010: Terraform Over CloudFormation or CDK

**Status**: Accepted
**Date**: 2026-05-11

### Context

The IaC tool choice has long-term consequences for skill development, ecosystem fit, and portability.

### Decision

Use Terraform.

### Rationale

- Terraform is already used in CloudHunt; using it in SandCastle aligns my entire personal portfolio on one IaC tool
- Terraform has the largest market share for cloud engineering jobs; CloudFormation is AWS-only and CDK is a smaller market
- HCL is more readable than CloudFormation JSON/YAML for long-form configurations
- The `pre-commit` hooks (`terraform fmt`, `terraform validate`, `tflint`) are mature and provide a polished dev experience
- State management via S3 + DynamoDB is a well-understood pattern that I want to demonstrate fluency in

### Consequences

- Need to manage Terraform state explicitly (handled via a dedicated state bucket per project)
- Terraform's drift detection is less integrated with AWS than CloudFormation's (acceptable for this use case)

---

## ADR-011: Resource Naming Convention `sandcastle-*`

**Status**: Accepted
**Date**: 2026-05-11

### Context

A consistent resource naming convention makes IAM policies, Cost Explorer filters, and cleanup operations significantly easier.

### Decision

All AWS resources for this project are named `sandcastle-<resource-purpose>` (lowercase, hyphen-separated). All resources are tagged with `Project=sandcastle`, `Owner=hussain`, `ManagedBy=terraform`, and (where applicable) `AutoStop=true`.

### Rationale

- Prefix-based filtering: `aws ec2 describe-instances --filters 'Name=tag:Project,Values=sandcastle'` becomes trivial
- IAM policies can use `arn:aws:*:*:*:*sandcastle*` patterns for project-scoped permissions
- Cost Explorer's tag-based grouping immediately surfaces SandCastle's share of the bill
- Avoids the CloudHunt mistake: the original AWS resources for that project were named `jobhunt-*` before the project was renamed, and those names are now stuck. Choosing the right name *first* is cheap; renaming later is not.

### Consequences

- Slight verbosity in resource names
- Future me will thank present me when I'm searching for "what does this orphaned resource belong to" six months from now

---

## ADR-012: Documentation-First Project Approach

**Status**: Accepted
**Date**: 2026-05-11

### Context

Many personal projects start with code and end without documentation, which limits their value as portfolio pieces and reduces their interview signal.

### Decision

Write documentation (README, architecture, ADRs, runbook) *before* writing implementation code. Treat the documentation as the primary deliverable; code is the implementation of the documented design.

### Rationale

- Forces clear thinking about the design before committing to it
- Produces interview artifacts that exist from day one
- Mirrors how real engineering teams work (design docs precede implementation)
- Makes scope creep visible early — if a new feature doesn't fit cleanly in the existing docs, that's a signal to pause

### Consequences

- Slower start (a weekend of documentation before any `terraform apply`)
- Much higher signal-to-noise ratio in the final portfolio piece
- Documentation itself becomes a portfolio artifact
