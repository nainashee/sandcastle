# Security

This document describes SandCastle's threat model, security controls, and alignment with the AWS Well-Architected Framework Security Pillar.

SandCastle is a personal development environment, not a regulated production system. The security posture is calibrated accordingly — strong defaults, defense in depth, but no controls that would be excessive for personal use.

---

## Threat Model

### Assets

| Asset | Sensitivity | Why It Matters |
|-------|-------------|----------------|
| AWS account credentials (account 989126024881) | High | Full control of personal infrastructure, billing exposure |
| GitHub SSH/PAT for `nainashee` | High | Source code integrity, supply chain risk |
| Project source code (CloudHunt, PlayHowzat, etc.) | Medium | Public repos, but unreleased commits could be exposed |
| Personal data on the instance (shell history, notes) | Low-Medium | Privacy concern, not financial |
| EBS snapshots in AWS Backup | Medium | Contains everything above |

### Threat Actors

| Actor | Capability | Likelihood | Impact |
|-------|------------|-----------:|-------:|
| Opportunistic internet scanner | Low (port-scanning, credential stuffing) | High | Low (no inbound surface) |
| Targeted attacker with leaked AWS key | High | Low | Catastrophic |
| Insider at AWS (theoretical) | Very High | Very Low | Catastrophic |
| Compromised dependency (supply chain) | Medium | Medium | Medium-High |
| Stolen laptop (work or personal) | Medium | Low | Low (no creds on laptop with SSM) |
| Misconfiguration by me | High | Medium | Medium |

The most realistic high-impact threats are **leaked AWS credentials** and **my own misconfiguration**. The controls below prioritize defenses against these.

---

## Security Controls

### Network

| Control | Implementation |
|---------|----------------|
| No inbound network access | Security group `sandcastle-keep-sg` has zero ingress rules |
| Outbound restricted to required services | Egress allowed to 0.0.0.0/0 (acceptable for dev box; SSM, GitHub, package mirrors required) |
| Public IP exists but is unreachable | SG blocks all inbound; effectively private |
| IMDSv2 required | Token-based access only, prevents SSRF-style metadata exfiltration |

### Identity and Access

| Control | Implementation |
|---------|----------------|
| No static AWS credentials on the instance | IAM instance profile provides temporary creds via IMDSv2 |
| Least-privilege instance role | `sandcastle-keep-role` only has SSM core, CloudWatch agent, and `sts:AssumeRole` on project roles |
| Per-project IAM roles | CloudHunt, PlayHowzat, LaunchPad each have their own dedicated dev role |
| MFA on the root account | Hardware MFA on the AWS account root user |
| No root account usage for daily work | IAM user `launchpad-dev` is used for terraform operations |
| GitHub SSH key generated fresh on the keep | Key never leaves the instance; can be revoked independently |

### Data Protection

| Control | Implementation |
|---------|----------------|
| EBS volume encrypted at rest | `alias/aws/ebs` AWS-managed KMS key |
| EBS snapshots encrypted | Inherited from source volume encryption |
| SSM session traffic encrypted in transit | TLS 1.2+ end-to-end |
| Terraform state encrypted at rest | S3 bucket with `SSE-S3` encryption enabled |
| Terraform state versioned | S3 versioning prevents accidental state loss |
| Terraform state locked | DynamoDB lock table prevents concurrent modification |

### Logging and Detection

| Control | Implementation |
|---------|----------------|
| CloudTrail enabled for management events | Trail `sandcastle-trail` writes to a dedicated S3 bucket |
| SSM session logging | Every session logged to CloudWatch Logs group `/aws/ssm/sessions/sandcastle` |
| CloudWatch alarms for anomalies | Billing, CPU credit, status check, disk usage |
| GuardDuty enabled | Account-wide; detects credential exfiltration and other threats |

### Operations

| Control | Implementation |
|---------|----------------|
| Automated patching | SSM Patch Manager applies critical and important patches weekly |
| Backup retention | 14 days, daily snapshots via AWS Backup |
| Tested restore procedure | Documented in [runbook.md](runbook.md#restore-from-snapshot) |
| Infrastructure as code | All resources reproducible via `terraform apply` |
| Pre-commit hooks | `terraform fmt`, `terraform validate`, `tflint`, `gitleaks` |

---

## Specific Risks and Mitigations

### Risk: Compromised IAM credentials

**Scenario**: A leaked access key for `launchpad-dev` or another IAM user is discovered by an attacker.

**Mitigations**:
- IAM Access Analyzer enabled to detect external access
- CloudTrail alarms on `iam:CreateUser`, `iam:AttachUserPolicy`, `iam:CreateAccessKey` from unusual locations
- Billing alarm catches runaway resource creation within 24 hours
- All sensitive operations require MFA via IAM condition keys
- Rotation: access keys are rotated quarterly via a calendar reminder

**Detection**: GuardDuty `UnauthorizedAccess:IAMUser/*` findings, CloudWatch billing alarm, Cost Anomaly Detection.

**Response**: See [runbook.md – Incident Response](runbook.md#incident-response).

### Risk: Compromised EC2 instance

**Scenario**: A vulnerability in installed software or a malicious package allows code execution on the keep.

**Mitigations**:
- IMDSv2 required prevents SSRF-based credential theft from the instance metadata service
- Instance role permissions are scoped to `sts:AssumeRole` of project roles, not broad admin
- No long-lived credentials on disk
- SSM Session Manager logs every interactive session
- Outbound traffic is unrestricted but goes through the AWS network; suspicious destinations would appear in VPC Flow Logs (Phase 3)

**Detection**: GuardDuty `Backdoor:EC2/*`, `CryptoCurrency:EC2/*`, unusual CloudWatch metrics.

**Response**: Isolate via security group (replace SG with a deny-all), snapshot for forensics, terminate the instance, restore from a clean snapshot.

### Risk: Stolen laptop

**Scenario**: My work or personal laptop is stolen.

**Mitigations**:
- No long-lived AWS credentials stored on the laptop (SSM uses temporary creds from `aws sso login` or my IAM user's profile)
- Laptop disk is encrypted (BitLocker on Windows)
- GitHub SSH key is on the keep, not the laptop
- Revoking access is straightforward: rotate the IAM user's access keys, revoke any GitHub OAuth sessions

**Note**: This is a primary reason for the SandCastle architecture. With sensitive credentials and source code on the keep rather than the laptop, the laptop is reduced to a thin client and its loss is significantly less damaging.

### Risk: Account-wide compromise

**Scenario**: An attacker gains root-level access to the AWS account.

**Mitigations**:
- Root account is locked down: hardware MFA, no programmatic access keys, used only for billing
- Daily Cost Anomaly Detection
- Critical alarms route to a personal email outside the compromised account
- AWS Backup vault has a separate access policy; snapshots can survive account-level deletion of source resources

**Note**: This is the worst-case scenario and the hardest to fully defend against. The mitigations focus on early detection and the ability to recover the account.

---

## Well-Architected Framework: Security Pillar Alignment

The AWS Well-Architected Security Pillar defines seven design principles. SandCastle's alignment:

| Principle | Implementation |
|-----------|----------------|
| **Implement a strong identity foundation** | IAM instance profile, no static keys, MFA on root, least-privilege roles |
| **Maintain traceability** | CloudTrail for management events, SSM session logging, VPC Flow Logs (Phase 3) |
| **Apply security at all layers** | Network (SG with no ingress), identity (IAM), data (encryption at rest and in transit), compute (IMDSv2, patching) |
| **Automate security best practices** | IaC ensures consistent baseline; pre-commit hooks catch issues; GuardDuty runs continuously |
| **Protect data in transit and at rest** | All EBS encrypted, all SSM sessions TLS-encrypted, state bucket encrypted |
| **Keep people away from data** | No SSH key sharing, no shared accounts, SSM provides audited access |
| **Prepare for security events** | Documented runbook, AWS Backup, tested restore procedure |

---

## What I Deliberately Don't Have (And Why)

| Control | Why Not |
|---------|---------|
| AWS WAF | No public-facing application on the keep |
| AWS Shield Advanced | $3,000/month; only relevant for DDoS-prone public workloads |
| Macie | No S3 buckets with sensitive data to scan |
| Security Hub paid tier | Overkill for a single-account, single-environment setup |
| KMS Customer Managed Keys | AWS-managed keys are sufficient for personal use; CMKs add cost and complexity |
| Private subnets + NAT Gateway | See [ADR-008](design-decisions.md#adr-008-public-subnet-without-nat-gateway) |
| Dedicated security audit account | Single-account is fine at this scale |

These are reasonable controls for production workloads but would be theater for a personal dev environment. The goal is *appropriate* security, not maximum security.

---

## Compliance Notes

SandCastle is not subject to any compliance framework (HIPAA, PCI-DSS, FedRAMP, etc.) because it does not process regulated data. However, several controls implemented here would satisfy or partially satisfy common compliance requirements:

- **NIST 800-53 AC-2 (Account Management)**: IAM users, role-based access, MFA
- **NIST 800-53 AU-2 (Audit Events)**: CloudTrail, SSM session logs
- **NIST 800-53 SC-13 (Cryptographic Protection)**: EBS encryption, TLS in transit
- **NIST 800-53 CP-9 (System Backup)**: AWS Backup with retention

This matters because I'm targeting government/public sector cloud roles. Familiarity with these mappings is a concrete skill those employers test for.
