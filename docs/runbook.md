# Operational Runbook

This runbook documents the day-2 operations for SandCastle: routine tasks, troubleshooting, incident response, and disaster recovery procedures.

## Conventions

- `<instance-id>` should be replaced with the instance ID, available via `terraform output instance_id` or by tag lookup.
- All commands assume `AWS_PROFILE=launchpad` and `AWS_REGION=us-east-1` unless otherwise noted.

---

## Daily Operations

### Start the Instance

```bash
aws ec2 start-instances --instance-ids $(terraform -chdir=terraform output -raw instance_id)
aws ec2 wait instance-status-ok --instance-ids $(terraform -chdir=terraform output -raw instance_id)
```

Or via the helper script:

```bash
./scripts/connect.sh --start
```

Startup takes approximately 60-90 seconds before SSM accepts a session.

### Connect to the Instance

```bash
aws ssm start-session --target $(terraform -chdir=terraform output -raw instance_id)
```

Or:

```bash
./scripts/connect.sh
```

### Stop the Instance

The auto-stop Lambda runs nightly. To stop manually:

```bash
aws ec2 stop-instances --instance-ids $(terraform -chdir=terraform output -raw instance_id)
```

### Check Instance Status

```bash
aws ec2 describe-instances \
  --instance-ids $(terraform -chdir=terraform output -raw instance_id) \
  --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PublicIpAddress,LaunchTime]' \
  --output table
```

---

## Backup and Recovery

### Manual Snapshot

Take an ad-hoc snapshot before risky operations (kernel upgrades, major package changes):

```bash
./scripts/snapshot.sh "pre-upgrade-$(date +%Y-%m-%d)"
```

Or directly:

```bash
VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids $(terraform -chdir=terraform output -raw instance_id) \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text)

aws ec2 create-snapshot \
  --volume-id $VOLUME_ID \
  --description "Manual snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Project,Value=sandcastle},{Key=Type,Value=manual}]'
```

### List Available Snapshots

```bash
aws ec2 describe-snapshots \
  --filters "Name=tag:Project,Values=sandcastle" \
  --query 'Snapshots[*].[SnapshotId,StartTime,Description,State]' \
  --output table
```

### Restore from Snapshot

This procedure restores the keep's data from a snapshot. The instance is destroyed and recreated.

**Prerequisites**:
- The desired snapshot ID
- Confirmation that the current EBS volume can be discarded

**Procedure**:

1. **Stop the instance**
   ```bash
   aws ec2 stop-instances --instance-ids $(terraform -chdir=terraform output -raw instance_id)
   aws ec2 wait instance-stopped --instance-ids $(terraform -chdir=terraform output -raw instance_id)
   ```

2. **Set the snapshot ID in Terraform**

   Edit `terraform/terraform.tfvars` (or pass via `-var`):
   ```hcl
   restore_from_snapshot_id = "snap-0abc123def456"
   ```

3. **Apply Terraform**
   ```bash
   cd terraform
   terraform apply
   ```

   Terraform will detach the old volume, create a new volume from the snapshot, and attach it as the root device. The old volume is deleted (snapshots remain).

4. **Verify**
   ```bash
   ./scripts/connect.sh
   # In the SSM session:
   ls -la ~/dev/
   cat /var/log/sandcastle-bootstrap.complete
   ```

5. **Clean up the variable**

   Remove `restore_from_snapshot_id` from `terraform.tfvars` to prevent accidental re-restores on the next apply.

**Recovery time**: ~10 minutes from start of procedure to working environment.

---

## Maintenance Operations

### Resize Instance

To change instance type (e.g., upgrade from `t3.medium` to `t3.large`):

1. Stop the instance
   ```bash
   aws ec2 stop-instances --instance-ids <instance-id>
   aws ec2 wait instance-stopped --instance-ids <instance-id>
   ```

2. Update `instance_type` in `terraform/terraform.tfvars`

3. Apply
   ```bash
   terraform apply
   ```

4. Start the instance
   ```bash
   aws ec2 start-instances --instance-ids <instance-id>
   ```

Downtime: ~2 minutes.

### Expand EBS Volume

To grow the root volume (e.g., 50 GB → 100 GB):

1. Update `root_volume_size` in `terraform/terraform.tfvars`

2. Apply
   ```bash
   terraform apply
   ```

   This modifies the volume in place. No downtime is required for EBS modification, but the OS won't see the new space until the filesystem is grown.

3. Connect to the instance and grow the filesystem
   ```bash
   sudo growpart /dev/nvme0n1 1
   sudo xfs_growfs -d /
   df -h /
   ```

**Note**: EBS volumes can only be modified once every 6 hours.

### Patch the Instance

Patching is automated via SSM Patch Manager weekly. For an immediate ad-hoc patch run:

```bash
aws ssm send-command \
  --instance-ids $(terraform -chdir=terraform output -raw instance_id) \
  --document-name "AWS-RunPatchBaseline" \
  --parameters "Operation=Install"
```

Track progress:

```bash
aws ssm list-command-invocations --details
```

---

## Incident Response

### Suspected Compromise

If you suspect the instance or AWS credentials have been compromised:

**Step 1: Contain**

Replace the security group with a deny-all SG to isolate the instance immediately while preserving it for forensics:

```bash
# Create a temporary isolation SG (no inbound, no outbound)
ISOLATION_SG=$(aws ec2 create-security-group \
  --group-name sandcastle-isolation-$(date +%s) \
  --description "Temporary isolation SG" \
  --vpc-id <vpc-id> \
  --query GroupId --output text)

# Revoke its default egress
aws ec2 revoke-security-group-egress \
  --group-id $ISOLATION_SG \
  --protocol all --cidr 0.0.0.0/0

# Apply to the instance
aws ec2 modify-instance-attribute \
  --instance-id <instance-id> \
  --groups $ISOLATION_SG
```

**Step 2: Snapshot for Forensics**

```bash
./scripts/snapshot.sh "incident-$(date +%Y%m%d-%H%M)"
```

Tag the snapshot with `Purpose=incident-forensics` to prevent the AWS Backup lifecycle from deleting it.

**Step 3: Rotate Credentials**

```bash
# Rotate IAM access keys for any users that might be affected
aws iam create-access-key --user-name launchpad-dev
# (Store new key securely, then deactivate the old one)
aws iam update-access-key --user-name launchpad-dev --access-key-id <old-key-id> --status Inactive

# Rotate GitHub SSH key
# - Generate new key on a known-clean machine
# - Replace the public key in GitHub
# - Delete the old key from GitHub
```

**Step 4: Investigate**

Review:
- CloudTrail events for unusual API calls in the past 7 days
- SSM session logs for unauthorized sessions
- GuardDuty findings
- The forensics snapshot (attach to a separate analysis instance)

**Step 5: Rebuild**

Once root cause is identified, destroy the compromised instance and rebuild:

```bash
cd terraform
terraform destroy -target=module.compute
terraform apply
```

Restore data from a *pre-compromise* snapshot, not the forensics snapshot.

### Billing Alarm Fired

If the billing alarm fires above $25/month:

1. Check Cost Explorer filtered to `Project=sandcastle` to identify the cost driver
2. Common culprits:
   - Instance left running (check via `aws ec2 describe-instances`)
   - Auto-stop Lambda failing (check CloudWatch Logs for `/aws/lambda/sandcastle-auto-stop`)
   - Snapshots accumulating beyond retention (check AWS Backup lifecycle)
   - Unexpected data egress (check VPC Flow Logs if enabled)
3. Take corrective action and document in `LEARNINGS.md`

### Instance Won't Start

```bash
aws ec2 start-instances --instance-ids <instance-id>
# Returns an error or instance shows as 'pending' indefinitely
```

Troubleshooting:

1. Check the system console output
   ```bash
   aws ec2 get-console-output --instance-id <instance-id> --output text
   ```

2. Check status check details
   ```bash
   aws ec2 describe-instance-status --instance-ids <instance-id>
   ```

3. If the instance is stuck, force-stop and start
   ```bash
   aws ec2 stop-instances --instance-ids <instance-id> --force
   aws ec2 wait instance-stopped --instance-ids <instance-id>
   aws ec2 start-instances --instance-ids <instance-id>
   ```

4. If still failing, restore from the most recent snapshot (see [Restore from Snapshot](#restore-from-snapshot))

### SSM Session Won't Connect

```bash
aws ssm start-session --target <instance-id>
# Returns: TargetNotConnected
```

Troubleshooting:

1. Verify the instance is running
   ```bash
   aws ec2 describe-instance-status --instance-ids <instance-id>
   ```

2. Verify the SSM agent is online
   ```bash
   aws ssm describe-instance-information \
     --filters "Key=InstanceIds,Values=<instance-id>"
   ```

   If the instance doesn't appear, the SSM agent isn't reporting in. Possible causes:
   - Instance profile missing or doesn't have `AmazonSSMManagedInstanceCore`
   - Outbound internet access broken (check security group, route table)
   - SSM agent crashed (reboot the instance via EC2 console)

3. Last-resort recovery: detach the instance, attach the EBS volume to a new instance, investigate offline.

---

## Disaster Recovery

### Complete Account Loss Scenario

If the entire AWS account is compromised or accidentally deleted:

1. **Snapshots in AWS Backup vault may survive** depending on the vault's access policy. Verify before assuming total loss.

2. **Terraform state is in S3** (`sandcastle-terraform-state-989126024881`). If this bucket is intact, recovery is straightforward.

3. **Code is in GitHub** (`nainashee/sandcastle`). All infrastructure code is reproducible.

4. **Recovery steps**:
   - Provision a new AWS account
   - Bootstrap a new state backend (`./bootstrap/bootstrap-state-backend.sh`)
   - Update `backend.tf` with the new bucket name
   - `terraform init -reconfigure`
   - `terraform apply`
   - Restore data from the most recent AWS Backup recovery point (if accessible)

**RTO**: ~4 hours
**RPO**: 24 hours (daily backup cadence)

### Single Region Outage

us-east-1 has historically had higher rates of major outages than other regions. If `us-east-1` is unavailable:

- The instance is unreachable until the outage resolves
- Work continues locally on the laptop
- No data is lost (EBS is durable across multiple physical locations within an AZ)

There is no multi-region DR strategy because the cost (replicating EBS to another region: $4-8/month) doesn't justify the marginal availability gain for a personal dev environment.

---

## Routine Maintenance Calendar

| Frequency | Task |
|-----------|------|
| Daily | Review CloudWatch alarms for any fired states |
| Weekly | Automated patch run (Sunday 02:00 UTC) |
| Weekly | Auto-stop Lambda logs review (sanity check) |
| Monthly | Cost Explorer review, compare against projection |
| Quarterly | Rotate IAM access keys |
| Quarterly | Test restore procedure on a non-production instance |
| Quarterly | Review and update this runbook |
| Annually | Review all ADRs; supersede any that no longer reflect reality |

---

## Helpful Commands Reference

```bash
# Get the instance ID
terraform -chdir=terraform output -raw instance_id

# Tail Lambda logs for the auto-stop function
aws logs tail /aws/lambda/sandcastle-auto-stop --follow

# View recent SSM sessions
aws ssm describe-sessions --state History --max-results 10

# Trigger the auto-stop Lambda manually (for testing)
aws lambda invoke --function-name sandcastle-auto-stop /tmp/response.json && cat /tmp/response.json

# Check current month's cost
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --filter '{"Tags": {"Key": "Project", "Values": ["sandcastle"]}}'

# Force the SSM agent to re-register (run on the instance)
sudo systemctl restart amazon-ssm-agent

# Manually run user-data bootstrap script (on the instance)
sudo /var/lib/cloud/instance/scripts/part-001
```
