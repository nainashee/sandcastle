# Cost Analysis

This document breaks down the projected and actual monthly cost of SandCastle, identifies the FinOps strategies used to control it, and provides a framework for ongoing cost monitoring.

All prices are AWS list prices for `us-east-1` as of May 2026. Actual costs will vary; see [Validation](#validation) below for how to verify against your AWS bill.

---

## Projected Monthly Cost

### Scenario A: Always-On

Instance runs 24/7. This is the baseline against which auto-stop savings are measured.

| Service | Resource | Unit Cost | Quantity | Monthly Cost |
|---------|----------|----------:|---------:|-------------:|
| EC2 | t3.medium On-Demand | $0.0416/hr | 730 hrs | $30.37 |
| EBS | gp3 storage | $0.08/GB-mo | 50 GB | $4.00 |
| EBS | gp3 baseline IOPS | included | 3,000 | $0.00 |
| EBS | gp3 baseline throughput | included | 125 MB/s | $0.00 |
| Data Transfer | Outbound to internet | $0.09/GB | ~5 GB | $0.45 |
| Lambda | auto-stop invocations | $0.20/M req | 22/mo | <$0.01 |
| Lambda | auto-stop duration | $0.0000166667/GB-s | 22 × 1s × 0.128 GB | <$0.01 |
| CloudWatch | Custom metrics | $0.30/metric-mo | 3 metrics | $0.90 |
| CloudWatch | Alarm metrics | $0.10/alarm-mo | 4 alarms | $0.40 |
| CloudWatch | Logs ingestion | $0.50/GB | ~0.1 GB | $0.05 |
| AWS Backup | EBS snapshot storage | $0.05/GB-mo | ~25 GB avg | $1.25 |
| CloudTrail | Management events | free | unlimited | $0.00 |
| SNS | Email notifications | $2/100k | <100 | <$0.01 |
| **Total** | | | | **~$37.45/mo** |

### Scenario B: Auto-Stop Enabled (Recommended)

Instance runs ~4 hours/day × 5 weekdays = 20 hours/week = ~87 hours/month.

| Service | Resource | Unit Cost | Quantity | Monthly Cost |
|---------|----------|----------:|---------:|-------------:|
| EC2 | t3.medium On-Demand | $0.0416/hr | 87 hrs | $3.62 |
| EBS | gp3 storage | $0.08/GB-mo | 50 GB | $4.00 |
| Data Transfer | Outbound to internet | $0.09/GB | ~2 GB | $0.18 |
| Lambda | auto-stop invocations | $0.20/M req | 22/mo | <$0.01 |
| CloudWatch | Custom metrics + alarms | mixed | various | $1.30 |
| CloudWatch | Logs ingestion | $0.50/GB | ~0.1 GB | $0.05 |
| AWS Backup | EBS snapshot storage | $0.05/GB-mo | ~25 GB avg | $1.25 |
| CloudTrail | Management events | free | unlimited | $0.00 |
| **Total** | | | | **~$10.41/mo** |

### Savings Summary

| Metric | Value |
|--------|------:|
| Always-on cost | $37.45/mo |
| Auto-stop cost | $10.41/mo |
| **Absolute savings** | **$27.04/mo** |
| **Percentage savings** | **72.2%** |
| Annual savings | $324.48/yr |

---

## Cost Drivers and What Changes Them

| Driver | Effect of Increase |
|--------|---------------------|
| Hours instance is running | Linear increase in EC2 compute |
| Instance size (e.g., upgrade to t3.large) | ~2× compute cost per size tier |
| EBS volume size | $0.08/GB linear |
| Outbound data transfer | $0.09/GB after 100 GB free tier |
| Number of EBS snapshots retained | $0.05/GB-mo of snapshot data |

Of these, **hours running** is the dominant variable. The auto-stop Lambda is the single most impactful cost control in the design.

---

## FinOps Strategies in Use

### 1. EventBridge + Lambda Auto-Stop ("the tide")

The keep is tagged `AutoStop=true`. A nightly EventBridge rule invokes a Lambda that stops all instances with this tag. Implementation details in [architecture.md](architecture.md#auto-stop-the-tide).

**Impact**: Reduces compute hours from 730 to ~87 per month — a 88% reduction in EC2 compute spend.

### 2. gp3 over gp2 EBS

gp3 is approximately 20% cheaper per GB than gp2, and decouples IOPS/throughput from volume size.

**Impact**: ~$1/month saved on a 50 GB volume vs gp2.

### 3. Single AZ, No NAT Gateway

A multi-AZ deployment with private subnets would require a NAT Gateway at ~$33/month plus data processing fees. SandCastle's public subnet + restrictive security group design avoids this entirely.

**Impact**: ~$33/month saved.

### 4. No Detailed Monitoring

EC2 detailed monitoring (1-minute metrics) costs ~$2.10/month per instance. SandCastle uses default 5-minute metrics, which are sufficient for a personal dev environment.

**Impact**: ~$2/month saved.

### 5. Reserved Instance / Savings Plan? — Not Yet

A 1-year Savings Plan would save ~30% on EC2 compute, but with auto-stop already cutting hours by 88%, the absolute dollar savings of a Savings Plan would be ~$1/month — not worth the 1-year commitment for a personal project. Revisit if I commit to running multiple instances or a larger workload.

### 6. Billing Alarm

A CloudWatch billing alarm fires at $25/mo estimated charges. This is set ~2.5× the expected auto-stop cost as a sanity check — if I'm hitting $25, something is wrong (instance stuck running, runaway Lambda, accidentally enlarged volume).

### 7. Tag-Based Cost Allocation

Every resource is tagged `Project=sandcastle`. The AWS account has cost allocation tags enabled for `Project`, allowing Cost Explorer to show SandCastle's monthly spend isolated from CloudHunt, PlayHowzat, and other workloads in the same account.

---

## Cost Comparison: Alternatives I Considered

| Alternative | Estimated Cost | Why Rejected |
|-------------|---------------:|--------------|
| Used ThinkPad laptop | $400 upfront, $0/mo | Doesn't teach AWS skills, doesn't solve work/personal separation |
| GitHub Codespaces (4-core, 60 hrs/mo) | ~$18/mo | Doesn't expose me to AWS infrastructure ops |
| Gitpod paid tier | ~$25/mo | Same as Codespaces; less control |
| Lightsail $10 instance | $10/mo | Less learning value; Lightsail is a managed abstraction |
| Self-hosted home server | $200+ upfront + electricity | More work, no cloud skill development |
| Free tier t3.micro for 12 months | $0/mo for 12 mo | Too small to be usable; cliff after 12 months |

SandCastle on `t3.medium` with auto-stop ($10/mo) is in the same price range as the SaaS alternatives, while providing far more learning value and complete control over the environment.

---

## Validation

After Phase 1 deploys, validate actual costs against this projection.

### Daily Sanity Check

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -d '7 days ago' +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
  --granularity DAILY \
  --metrics UnblendedCost \
  --filter '{"Tags": {"Key": "Project", "Values": ["sandcastle"]}}' \
  --profile launchpad
```

### Monthly Review

On the 1st of each month, run a Cost Explorer report for the previous month grouped by service, filtered to `Project=sandcastle`. Compare against this document's projection. Variance > 20% should trigger an investigation.

### Cost Anomaly Detection

AWS Cost Anomaly Detection is configured for the `sandcastle` cost allocation tag. Anomalies of >$5 above the historical baseline trigger an email notification.

---

## Future Cost Optimization Opportunities

These are not implemented now but are candidates for future phases:

| Opportunity | Estimated Savings | Effort | Notes |
|-------------|-------------------|--------|-------|
| Switch to t4g.medium (ARM) | ~$1.50/mo | Low | Pending ARM compatibility validation; see ADR-007 |
| 1-year Compute Savings Plan | ~$1/mo | Low | Locks in 1-year commitment for marginal benefit |
| Spot instance | Up to $2/mo | Medium | Risk of interruption mid-session; not worth the friction |
| Reduce EBS to 30 GB | ~$1.60/mo | Low | Only viable if I move project state off the box |
| Delete unused snapshots aggressively | Variable | Low | Already capped at 14-day retention |

Total optimization headroom: ~$6/month. The auto-stop Lambda already captures ~75% of the available cost savings; additional optimizations are diminishing returns.

---

## Cost as Portfolio Signal

A point worth making explicit: this document itself is a portfolio artifact. Hiring managers and senior engineers care deeply about cost-aware design because they've seen junior engineers spin up `m5.4xlarge` instances "to be safe" and forget about them. Demonstrating that you can:

1. Project costs before deploying
2. Validate projections after deploying
3. Implement automated cost controls
4. Articulate trade-offs in dollar terms

...is exactly the FinOps maturity that distinguishes a thoughtful cloud engineer from someone who follows tutorials. This document is here partly because it's useful and partly because the interview question "tell me about a time you optimized cloud spend" deserves a real answer.
