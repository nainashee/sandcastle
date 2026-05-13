<#
.SYNOPSIS
    Bootstrap the Terraform state backend for SandCastle.

.DESCRIPTION
    One-time setup of the Terraform state backend.
    Creates an S3 bucket (versioned, encrypted) for Terraform state.
    Uses S3-native locking (use_lockfile = true) — requires Terraform 1.10+.
    No DynamoDB table needed.

    Run this ONCE, before the first `terraform init`.
    Idempotent: safe to run multiple times.

.EXAMPLE
    .\bootstrap-state-backend.ps1 -AwsProfile sandcastle
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$AwsProfile,

    [string]$AwsRegion = "us-east-1",
    [string]$ProjectName = "sandcastle"
)

# Stop on any error
$ErrorActionPreference = "Stop"

# ---- Look up account ID ----
Write-Host "==> Looking up AWS account ID..."
$AccountId = aws sts get-caller-identity --query Account --output text --profile $AwsProfile
if (-not $AccountId) {
    Write-Host "ERROR: Could not get account ID. Check that profile '$AwsProfile' exists and SSO session is valid." -ForegroundColor Red
    Write-Host "Try: aws sso login --sso-session nainashee"
    exit 1
}

$BucketName = "$ProjectName-terraform-state-$AccountId"

Write-Host ""
Write-Host "==> SandCastle state backend bootstrap (S3-native locking)"
Write-Host "    Region:  $AwsRegion"
Write-Host "    Profile: $AwsProfile"
Write-Host "    Account: $AccountId"
Write-Host "    Bucket:  $BucketName"
Write-Host ""

# ---- S3 Bucket ----
Write-Host "==> Creating S3 bucket for Terraform state..."
$bucketExists = $null
try {
    aws s3api head-bucket --bucket $BucketName --profile $AwsProfile 2>$null
    $bucketExists = $true
} catch {
    $bucketExists = $false
}

if ($LASTEXITCODE -eq 0) {
    Write-Host "    Bucket already exists. Skipping creation."
} else {
    aws s3api create-bucket `
        --bucket $BucketName `
        --region $AwsRegion `
        --profile $AwsProfile
    if ($LASTEXITCODE -ne 0) { throw "Failed to create bucket" }
    Write-Host "    Created bucket: $BucketName"
}

# Versioning: lets you roll back if state is corrupted
Write-Host "==> Enabling versioning on bucket..."
aws s3api put-bucket-versioning `
    --bucket $BucketName `
    --versioning-configuration Status=Enabled `
    --profile $AwsProfile
if ($LASTEXITCODE -ne 0) { throw "Failed to enable versioning" }

# Encryption: state files can contain sensitive resource data
Write-Host "==> Enabling default encryption (AES256)..."
$encryptionConfig = '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}'
aws s3api put-bucket-encryption `
    --bucket $BucketName `
    --server-side-encryption-configuration $encryptionConfig `
    --profile $AwsProfile
if ($LASTEXITCODE -ne 0) { throw "Failed to enable encryption" }

# Block public access: state should NEVER be public
Write-Host "==> Blocking all public access..."
aws s3api put-public-access-block `
    --bucket $BucketName `
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" `
    --profile $AwsProfile
if ($LASTEXITCODE -ne 0) { throw "Failed to block public access" }

# Tagging: for cost allocation
Write-Host "==> Tagging bucket..."
$tagSet = 'TagSet=[{Key=Project,Value=sandcastle},{Key=Owner,Value=hussain},{Key=ManagedBy,Value=bootstrap-script}]'
aws s3api put-bucket-tagging `
    --bucket $BucketName `
    --tagging $tagSet `
    --profile $AwsProfile
if ($LASTEXITCODE -ne 0) { throw "Failed to tag bucket" }

Write-Host ""
Write-Host "==> Done. Add this to terraform/backend.tf:" -ForegroundColor Green
Write-Host ""
Write-Host 'terraform {'
Write-Host '  required_version = ">= 1.10"'
Write-Host ''
Write-Host '  backend "s3" {'
Write-Host "    bucket       = `"$BucketName`""
Write-Host '    key          = "phase-1/terraform.tfstate"'
Write-Host "    region       = `"$AwsRegion`""
Write-Host '    encrypt      = true'
Write-Host '    use_lockfile = true'
Write-Host '  }'
Write-Host '}'
