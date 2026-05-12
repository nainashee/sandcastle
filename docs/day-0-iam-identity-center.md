# SandCastle Day 0 — IAM Identity Center Setup

> Day 0 goal: Establish proper AWS access management *before* building any infrastructure. By the end of this guide, you'll have AWS IAM Identity Center configured with permission sets for each of your projects, and your AWS CLI will use short-lived SSO credentials instead of long-lived access keys.

## How to Use This Guide

- **Time estimate**: 2.5–3 hours, including reading, doing, verifying, and the end-of-day reflection.
- **Do this BEFORE Phase 1 Day 1**. Phase 1's docs and scripts all assume your access model is in place.
- **This is a one-time setup**. You're building a foundation you'll use for years across all projects, not just SandCastle.
- **Don't paste blindly**. Read each "why" section. Identity Center has more concepts than typical IAM — understanding them matters.

## What You're Building Today

By the end of Day 0:

- AWS IAM Identity Center enabled in your account
- One Identity Center user (you) in the built-in directory
- Three permission sets: `SandCastleAdmin`, `CloudHuntAdmin`, `LaunchPadAdmin`
- AWS CLI v2 configured with SSO profiles for each project
- Your old IAM user (`launchpad-dev`) deactivated (not deleted yet — kept as a safety net)
- A `docs/aws-access.md` document explaining the model

```
                 ┌──────────────────────────────────────────────┐
                 │       AWS IAM Identity Center                │
                 │                                              │
                 │   ┌────────────────────────────────────┐     │
                 │   │  Identity Source: Built-in store   │     │
                 │   │  User: hussain.ashfaque            │     │
                 │   └─────────────────┬──────────────────┘     │
                 │                     │ assigned to            │
                 │     ┌───────────────┼───────────────┐        │
                 │     │               │               │        │
                 │     ▼               ▼               ▼        │
                 │  ┌──────┐       ┌──────┐        ┌──────┐    │
                 │  │ SC   │       │ CH   │        │ LP   │    │
                 │  │Admin │       │Admin │        │Admin │    │
                 │  └───┬──┘       └───┬──┘        └───┬──┘    │
                 └──────┼──────────────┼───────────────┼──────-┘
                        │              │               │
                        ▼              ▼               ▼
                 ┌──────────────────────────────────────────────┐
                 │  AWS Account 989126024881                    │
                 │  (Permission sets become assumable IAM roles)│
                 └──────────────────────────────────────────────┘
                        ▲              ▲               ▲
                        │              │               │
                        │              │               │
                 ┌──────┴──────────────┴───────────────┴──────┐
                 │   Your laptop: `aws sso login`              │
                 │   ↓                                          │
                 │   Browser: pick role, click "approve"        │
                 │   ↓                                          │
                 │   ~/.aws/sso/cache/*.json (1-hour creds)    │
                 │   ↓                                          │
                 │   `aws --profile sandcastle s3 ls` works    │
                 └─────────────────────────────────────────────┘
```

## Why Identity Center Instead of IAM Users

Before any clicks, understand *what* you're changing and *why*.

**The IAM user model (current state):**

```
You ──[long-lived access keys]──→ IAM user `launchpad-dev` ──[broad policies]──→ AWS API
```

**The Identity Center model (target state):**

```
You ──[SSO browser login]──→ Identity Center user ──[scoped permission set]──→ AWS API
                                                       (1-hour credentials)
```

Key shifts:

| Aspect | IAM User | Identity Center |
|--------|----------|-----------------|
| Credentials | Long-lived access keys stored on disk | Short-lived (1-12 hour) tokens cached in `~/.aws/sso/cache/` |
| Rotation | Manual, every 90 days (if you remember) | Automatic, every login |
| Project separation | One user per project, or one over-privileged user | One permission set per project, all under one identity |
| Audit trail | All actions attributed to one IAM user | Actions attributed to the SSO identity + permission set |
| Compromise blast radius | Total — keys can be exfiltrated and reused | Limited — tokens expire in hours |
| Cost | Free | Free |

This is the access pattern every modern AWS shop uses. Building this skill now compounds for every cloud engineering role you'll ever apply for.

---

## Step 1: Verify Account State (5 min)

Before anything else, confirm what kind of AWS setup you currently have. This determines the first move.

**On your laptop:**

```bash
aws organizations describe-organization --profile launchpad
```

There are three possible outcomes:

**Case A — Output shows organization details:**
```json
{
  "Organization": {
    "Id": "o-xxxxxxxxxx",
    ...
  }
}
```
You're already in an Organization. Excellent — you have the cleanest possible starting point. Skip to Step 2 directly.

**Case B — Error: `AccessDeniedException` or `AWSOrganizationsNotInUseException`:**
Your account 989126024881 is standalone, not part of an Organization. You need to create an Organization first (Step 1b below).

**Case C — Error: profile not found, credentials issue:**
Fix your CLI access first before proceeding.

### Step 1b: Create an AWS Organization (if Case B above)

This is a 60-second step that costs nothing and is **required** before Identity Center can be enabled cleanly.

```bash
aws organizations create-organization --profile launchpad
```

Expected output:
```json
{
  "Organization": {
    "Id": "o-xxxxxxxxxx",
    "MasterAccountId": "989126024881",
    ...
  }
}
```

Account 989126024881 is now both your management account AND a member account (which is fine for personal use). You can add more accounts later if you ever want true multi-account separation.

**Why is this needed?** Identity Center is designed to span multiple accounts. Even with one account, AWS requires the Organization wrapper to enable Identity Center. It's a 5-second activation, no cost, and unlocks the rest of the path.

---

## Step 2: Enable IAM Identity Center (15 min)

This is mostly clicking through the AWS Console, since some of the setup isn't well-exposed via CLI.

### 2a. Open Identity Center

1. Log into the AWS Console as your root user OR your existing `launchpad-dev` user (whichever has IAM admin permissions).
2. In the region selector (top right), **set your region to us-east-1**. Identity Center is regional. You can only have one instance per Organization, and the region is permanent — you cannot change it later. **Choose carefully.** us-east-1 is the right choice for you (matches everything else).
3. In the AWS search bar, type "IAM Identity Center" and select it.
4. Click **Enable**.

### 2b. Confirm enablement

After ~30 seconds, the dashboard appears with:
- An **AWS access portal URL** like `https://d-9067abc123.awsapps.com/start`
- Your **Identity source** showing "Identity Center directory" (the built-in option)

**Bookmark the portal URL immediately.** This is the URL you'll log into every day. Save it as a browser favorite called "AWS Portal" or similar.

### 2c. Optional but recommended: customize the portal URL

By default the URL has a random ID like `d-9067abc123`. You can customize it once.

1. In the Identity Center dashboard, find **Settings** in the left sidebar.
2. Find **Identity source** section, look for "AWS access portal URL".
3. Click the edit/customize option.
4. Change to something memorable: e.g., `nainashee` → URL becomes `https://nainashee.awsapps.com/start`.

**Warning**: This change is one-time-only. Choose something neutral and lasting. Don't include the project name (this URL outlives any single project).

---

## Step 3: Create Your Identity Center User (10 min)

Now create the user account that *you* will log in with. This is a separate identity from your IAM users — it lives in the Identity Center directory, not IAM.

### 3a. Create the user

1. In Identity Center → **Users** in the left sidebar → **Add user**.
2. Fill in:
   - **Username**: `hussain.ashfaque` (or whatever you'd like; this is what you'll type to log in)
   - **Email address**: your real email
   - **First name** / **Last name**: your name
   - **Display name**: how you want it shown in the portal
3. **Send email invitation** option: select "Send an email invitation to this user to set their password" — this is the safest path.
4. Click **Add user**.

### 3b. Verify and set password

Within a minute or two, you'll get an email titled something like "Invitation to join AWS Identity Center."

1. Click the **Accept invitation** link in the email.
2. Set a strong password.
3. Set up MFA. **Use a hardware security key (YubiKey) or your authenticator app** — do NOT skip this. Identity Center is the front door to everything; MFA is non-negotiable.

### 3c. Test login

1. Open the AWS access portal URL (the one you bookmarked).
2. Log in with your new username and password.
3. Complete MFA.

At this point you'll see an empty portal — no accounts or roles assigned yet. That's correct; we'll assign permission sets in the next step.

**Why a separate user from your IAM user?** IAM users and Identity Center users live in different systems. The Identity Center user is the *primary* identity going forward. The old `launchpad-dev` IAM user becomes a fallback you'll deactivate later.

---

## Step 4: Create Permission Sets (30 min)

Permission sets are the heart of Identity Center. A permission set is essentially "a named bundle of permissions" that becomes an IAM role in your account when assigned to a user.

You'll create three permission sets, one per project.

### 4a. Create the SandCastleAdmin permission set

1. Identity Center → **Permission sets** in the left sidebar → **Create permission set**.
2. Select **Predefined permission set** for the first one (we'll do custom in a later step).
3. Choose **AdministratorAccess** for now (we'll scope it down properly in a moment — let's get the workflow first).
4. Click **Next**.
5. **Permission set name**: `SandCastleAdmin`
6. **Description**: "Full admin access for SandCastle infrastructure work"
7. **Session duration**: 4 hours (default is 1 hour; 4 is more comfortable for long dev sessions, still secure)
8. **Relay state**: leave blank
9. **Tags**: add `Project=sandcastle`, `Owner=hussain`
10. Click **Next**, review, **Create**.

**Why AdministratorAccess initially?** You're learning the pattern. Once it works end-to-end, you'll create properly scoped permission sets (see Step 7 below). Don't optimize before things work.

### 4b. Create CloudHuntAdmin and LaunchPadAdmin

Repeat 4a twice more:

- `CloudHuntAdmin` with `AdministratorAccess`, 4-hour session, tag `Project=cloudhunt`
- `LaunchPadAdmin` with `AdministratorAccess`, 4-hour session, tag `Project=launchpad`

You should now have three permission sets visible in the Permission sets list.

### 4c. Why one set per project, even when they all have AdministratorAccess

It seems redundant — three permission sets all with the same policy. **Three reasons it's worth doing:**

1. **CloudTrail clarity**: When you assume `SandCastleAdmin`, CloudTrail logs that explicit role name. You can filter audit logs by which "hat" you were wearing.
2. **Future scoping**: When you tighten permissions later (Step 7), each set evolves independently. SandCastle might need EventBridge permissions that CloudHunt doesn't.
3. **Cognitive scaffolding**: When you log in and explicitly pick `SandCastleAdmin`, your brain context-switches to that project. Reduces the "wait, which project am I working on" moments.

---

## Step 5: Assign Permission Sets to Your AWS Account (15 min)

Permission sets exist but aren't yet usable. They need to be *assigned* to an account before they become live IAM roles in that account.

### 5a. Open the account assignment flow

1. Identity Center → **AWS accounts** in the left sidebar.
2. You'll see account 989126024881 listed.
3. Select the checkbox next to it.
4. Click **Assign users or groups**.

### 5b. Assign your user

1. **Users** tab → select your user (`hussain.ashfaque`) → **Next**.
2. **Permission sets**: select all three (`SandCastleAdmin`, `CloudHuntAdmin`, `LaunchPadAdmin`) → **Next**.
3. Review the assignments → **Submit**.

AWS will now provision IAM roles in your account corresponding to each permission set. This takes ~30 seconds. The roles will be named something like:

- `AWSReservedSSO_SandCastleAdmin_a1b2c3d4`
- `AWSReservedSSO_CloudHuntAdmin_e5f6g7h8`
- `AWSReservedSSO_LaunchPadAdmin_i9j0k1l2`

**Don't manually modify these IAM roles.** Identity Center manages them. If you need to change permissions, edit the permission set, not the role.

### 5c. Verify in the portal

1. Refresh your AWS access portal browser tab.
2. You should now see **Account 989126024881** with three roles available.
3. Click `SandCastleAdmin` → "Access keys" → you'll see the temporary credentials box.

You can either:
- Click "Management console" to open the AWS Console as that role
- Copy the access keys for one-off CLI usage
- Set up programmatic CLI access (Step 6 — this is what you actually want)

---

## Step 6: Configure AWS CLI for SSO (30 min)

This is the step that replaces `aws configure` (which uses long-lived keys) with `aws configure sso` (which uses Identity Center).

### 6a. Verify AWS CLI version

```bash
aws --version
```

You need v2.x. If you're on v1, install v2:

**Windows (PowerShell, before you migrate to WSL):**
```powershell
msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
```

**WSL/Linux:**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install --update
```

### 6b. Configure the first SSO profile (sandcastle)

```bash
aws configure sso
```

You'll be prompted interactively. Answer:

| Prompt | Answer |
|--------|--------|
| SSO session name | `nainashee` (you can name this anything; it's the reusable SSO session identifier) |
| SSO start URL | Your portal URL, e.g., `https://nainashee.awsapps.com/start` |
| SSO region | `us-east-1` |
| SSO registration scopes | `sso:account:access` (the default) |

A browser opens. Log in with your Identity Center credentials and approve the device authorization request.

Back in the terminal:

| Prompt | Answer |
|--------|--------|
| Account | Pick `989126024881` (the only option) |
| Role | Pick `SandCastleAdmin` |
| Default client region | `us-east-1` |
| Default output format | `json` |
| Profile name | `sandcastle` |

Done. Your `~/.aws/config` now has:

```ini
[sso-session nainashee]
sso_start_url = https://nainashee.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile sandcastle]
sso_session = nainashee
sso_account_id = 989126024881
sso_role_name = SandCastleAdmin
region = us-east-1
output = json
```

### 6c. Add the other two profiles

You don't need to repeat the full SSO setup — you can reuse the `nainashee` session. The fastest path is to edit `~/.aws/config` directly and add:

```ini
[profile cloudhunt]
sso_session = nainashee
sso_account_id = 989126024881
sso_role_name = CloudHuntAdmin
region = us-east-1
output = json

[profile launchpad]
sso_session = nainashee
sso_account_id = 989126024881
sso_role_name = LaunchPadAdmin
region = us-east-1
output = json
```

Note: **the profile name `launchpad` is being reused here** — but its meaning changes. Before, it was the IAM user `launchpad-dev`. Now, it's the SSO profile for LaunchPad work. This is fine because all the existing scripts that reference `--profile launchpad` will continue to work without modification.

### 6d. Test each profile

```bash
aws sts get-caller-identity --profile sandcastle
```

Expected output:
```json
{
  "UserId": "AROA...",
  "Account": "989126024881",
  "Arn": "arn:aws:sts::989126024881:assumed-role/AWSReservedSSO_SandCastleAdmin_xxx/hussain.ashfaque"
}
```

The `Arn` should show `AWSReservedSSO_SandCastleAdmin_xxx`. That's the proof you're using Identity Center.

Repeat for `cloudhunt` and `launchpad` profiles. Each should show its corresponding role name.

### 6e. The daily login workflow

Going forward, your daily flow is:

```bash
aws sso login --sso-session nainashee
```

This opens a browser, you click "approve," and **all three profiles** (`sandcastle`, `cloudhunt`, `launchpad`) become usable. The single login covers every profile that shares the `nainashee` SSO session.

Sessions last 8 hours by default. When they expire, just re-run `aws sso login`.

---

## Step 7: Tighten Permissions (Optional Now, Required Later)

You assigned `AdministratorAccess` to each permission set for simplicity. This is fine for personal use, but **a real cloud engineer would not stop here**. Here's how to scope them properly when you're ready.

### 7a. The right scope per project

For each permission set, the *minimum* required permissions are:

**SandCastleAdmin** needs:
- EC2 (instances, volumes, security groups, VPCs, subnets, IGW, route tables)
- IAM (roles, policies, instance profiles — limited to `sandcastle-*` resources)
- Lambda (for Phase 2 auto-stop function)
- EventBridge (for Phase 2 schedule)
- CloudWatch (alarms, dashboards, logs)
- S3 (state bucket access)
- DynamoDB (state lock table)
- SSM (session start, parameter read)
- KMS (decrypt for EBS)

**CloudHuntAdmin** needs:
- Lambda, API Gateway, DynamoDB, S3, CloudFront, EventBridge, IAM (limited to `cloudhunt-*`/`jobhunt-*`)

**LaunchPadAdmin** similar to CloudHunt with LaunchPad-specific resources.

### 7b. Approach: start with PowerUserAccess, then tighten

In Identity Center → Permission sets → SandCastleAdmin → Edit:

1. Remove `AdministratorAccess`.
2. Add `PowerUserAccess` (gives full access to all AWS services except IAM management).
3. Add a custom inline policy that grants the IAM permissions needed (creating roles for `sandcastle-*`, etc.).

Or, even better, use a **customer-managed permission set** (custom IAM policy) for each. This is a 1-hour task per permission set when you're ready.

### 7c. When to do this

**Defer Step 7 until after Phase 1 ships.** Right now you're learning Identity Center fundamentals. Tightening permissions is a separate skill (writing custom IAM policies) that deserves its own focused session. Premature optimization here will cause you to fight permission errors when you should be learning networking and EC2.

Mark this as a future task in `LEARNINGS.md`.

---

## Step 8: Deactivate (Don't Delete) the Old IAM User (10 min)

You're now operating fully under Identity Center. Time to retire the legacy `launchpad-dev` IAM user — but carefully.

### 8a. Why deactivate instead of delete

If something breaks with Identity Center, the IAM user is your backdoor. Keeping it disabled-but-existing for 2-4 weeks is cheap insurance. After you're confident Identity Center is solid, you can delete it.

### 8b. Deactivate the access keys

```bash
# Find the access keys
aws iam list-access-keys --user-name launchpad-dev --profile sandcastle

# Deactivate each one
aws iam update-access-key \
  --user-name launchpad-dev \
  --access-key-id AKIAXXXXXXXXXXXXXX \
  --status Inactive \
  --profile sandcastle
```

This **disables the keys** without deleting them. The user still exists; the keys still exist on the user; they just no longer work for API calls.

### 8c. Test that the old keys are dead

Try to use the old IAM user via the AWS CLI with its keys (if you remember them):

```bash
AWS_ACCESS_KEY_ID=<old-key> AWS_SECRET_ACCESS_KEY=<old-secret> aws sts get-caller-identity
```

Should fail with `InvalidClientTokenId`. Good.

### 8d. Mark a calendar reminder

Set a calendar reminder for **4 weeks from today**: "Delete `launchpad-dev` IAM user if Identity Center has been working without issue."

---

## Step 9: Document the Access Model (15 min)

Create `docs/aws-access.md` in your SandCastle repo:

```markdown
# AWS Access Model

SandCastle (and all my personal AWS projects) use **AWS IAM Identity Center** for human access, with **per-project permission sets** for separation and audit clarity.

## Identity

- **Identity Center directory**: `nainashee.awsapps.com/start`
- **Identity Center user**: `hussain.ashfaque`
- **MFA**: enforced via authenticator app

## Permission Sets

| Set | Project | Scope |
|-----|---------|-------|
| `SandCastleAdmin` | SandCastle | Full admin (will be tightened post-Phase 1) |
| `CloudHuntAdmin` | CloudHunt | Full admin |
| `LaunchPadAdmin` | LaunchPad | Full admin |

Each permission set has a 4-hour session duration.

## CLI Profiles

| Profile | Permission Set |
|---------|----------------|
| `sandcastle` | SandCastleAdmin |
| `cloudhunt` | CloudHuntAdmin |
| `launchpad` | LaunchPadAdmin |

All profiles share the `nainashee` SSO session. Run `aws sso login --sso-session nainashee` once per 8-hour window to authenticate all profiles.

## Daily Workflow

```bash
# Start of day (or after token expires)
aws sso login --sso-session nainashee

# Throughout the day, use the appropriate profile
aws --profile sandcastle s3 ls
terraform -chdir=terraform plan  # Uses AWS_PROFILE from env or default

# At end of day, no logout needed — tokens expire automatically
```

## Future Work

- [ ] Replace `AdministratorAccess` on each permission set with scoped customer-managed policies
- [ ] Add a `ReadOnly` permission set for safer exploratory work
- [ ] Consider AWS Organizations multi-account migration (separate accounts per project) — large project, future phase

## Emergency Access

The IAM user `launchpad-dev` is **deactivated** (keys inactive) but not deleted. If Identity Center is unavailable or broken:
1. Reactivate the keys via the AWS Console (logged in as root)
2. Use the old `~/.aws/credentials` entry

This fallback path will be removed once Identity Center has run cleanly for 4 weeks.
```

---

## Step 10: Commit and Wrap (5 min)

If you've already created the SandCastle repo:

```bash
cd ~/dev/sandcastle
git add docs/aws-access.md
git commit -m "Day 0: Document IAM Identity Center access model"
git push
```

If not yet, save `aws-access.md` somewhere safe; you'll add it during Phase 1 Day 1 when you create the repo.

---

## What You Built Today

A modern, audit-friendly, properly-scoped AWS access model with:

- IAM Identity Center enabled and configured
- One Identity Center user (you) with MFA
- Three permission sets, one per project
- AWS CLI v2 configured with SSO profiles
- Old IAM user safely deactivated
- Documentation of the model in your repo

This is the foundation **everything** else builds on. Phase 1 starts from here.

---

## End-of-Day Reflection

Add to `LEARNINGS.md`:

```markdown
## YYYY-MM-DD — Day 0: IAM Identity Center

**What I built**: Identity Center enabled, 3 permission sets, SSO profiles configured, MFA enforced, legacy IAM user deactivated.

**What I learned**: [your words]

**What surprised me**: [your words]

**Stuck moments**: [your words — be honest, this is a multi-step setup]

**Things I want to revisit**:
- [ ] Tighten permission sets from AdministratorAccess to scoped policies (Step 7)
- [ ] Delete `launchpad-dev` IAM user after 4-week burn-in
```

---

## Multiple Choice Quiz

**Q1.** What is the primary difference between an IAM user and an Identity Center user?
- A) IAM users cost money; Identity Center users are free
- B) IAM users use long-lived access keys; Identity Center users use short-lived SSO tokens
- C) IAM users can't access EC2; Identity Center users can
- D) There is no difference

**Q2.** When you assign a permission set to an AWS account, what actually gets created in that account?
- A) A new IAM user
- B) An IAM role (managed by Identity Center, prefixed with `AWSReservedSSO_`)
- C) A new access key
- D) A new VPC

**Q3.** Why is MFA non-negotiable on the Identity Center user?
- A) AWS requires it
- B) Identity Center is the front door to *all* your AWS access — a compromised SSO password without MFA exposes every project
- C) MFA is free
- D) It speeds up logins

**Q4.** What happens to your access keys when you use `aws sso login`?
- A) Long-lived keys are downloaded
- B) Short-lived credentials (1-12 hour) are cached in `~/.aws/sso/cache/`
- C) Your IAM user is re-enabled
- D) Nothing — the keys are static

**Q5.** Why create separate permission sets (`SandCastleAdmin`, `CloudHuntAdmin`, etc.) even when they all have the same policy initially?
- A) AWS requires one permission set per project
- B) CloudTrail logs the explicit role name, allowing per-project audit filtering; future scope tightening can diverge
- C) Permission sets are free, so why not
- D) It's faster

**Q6.** What does the `sso_session` block in `~/.aws/config` do?
- A) Stores your password
- B) Defines a reusable SSO session that multiple profiles can share, so one `aws sso login` authenticates all of them
- C) Caches the JWT token
- D) Enables MFA

**Q7.** Why deactivate the old `launchpad-dev` IAM user instead of deleting it immediately?
- A) Deletion is impossible
- B) It serves as an emergency fallback if Identity Center has issues during the burn-in period
- C) Deletion is expensive
- D) AWS requires a 30-day waiting period

**Q8.** What is the maximum session duration for a permission set?
- A) 1 hour
- B) 4 hours
- C) 12 hours
- D) 24 hours

**Q9.** If you change a permission set's policy in Identity Center, what happens to the corresponding IAM role in your account?
- A) Nothing — you must update the role manually
- B) Identity Center automatically updates the IAM role to reflect the new policy
- C) The role is deleted and recreated
- D) You must reassign the permission set

**Q10.** What's the right CLI command to authenticate all your SSO profiles at once?
- A) `aws configure`
- B) `aws login`
- C) `aws sso login --sso-session <session-name>`
- D) `aws iam authenticate`

<details>
<summary>Answers</summary>

1. **B** — The credential model is the fundamental difference. IAM users have static keys; Identity Center delivers short-lived, rotating credentials via the SSO mechanism. This single difference is what makes Identity Center vastly more secure.

2. **B** — Permission sets become IAM roles when assigned. They're managed by Identity Center (you shouldn't edit them directly), and they're named with the `AWSReservedSSO_` prefix to mark them as Identity Center-managed.

3. **B** — Single point of compromise. Without MFA, a leaked SSO password gives an attacker every project's worth of access. With MFA, password leak alone isn't enough.

4. **B** — The tokens are stored in `~/.aws/sso/cache/`. The AWS CLI reads them automatically when a profile references that session. They expire and you re-run `aws sso login` to refresh.

5. **B** — CloudTrail audit clarity plus the option for future divergence. Premature consolidation is harder to reverse than starting with separate sets.

6. **B** — `sso_session` blocks let multiple profiles share authentication state. One login covers all of them. Without sessions, you'd log in once per profile.

7. **B** — The IAM user is your safety net during burn-in. If Identity Center has unexpected issues, you can reactivate the IAM keys and keep working while you debug. Delete only after 4 weeks of successful Identity Center operation.

8. **C** — 12 hours is the absolute maximum. Default is 1 hour. 4 hours is a comfortable middle ground for personal dev work. Longer = less secure (longer-lived tokens); shorter = more interruptions.

9. **B** — Identity Center manages the lifecycle of those reserved roles. Edit the permission set, Identity Center propagates the change to every account it's assigned in. This is one of the major operational wins over manually managing IAM roles per account.

10. **C** — `aws sso login --sso-session <session-name>` is the command. With a default `sso_session` in your config, you can sometimes shorten to `aws sso login`, but being explicit is clearer.

</details>

---

## Interview Questions

These are the kinds of questions a cloud engineer interview will ask about identity and access management. Practice each in 2-3 minutes out loud.

1. **"Walk me through how IAM Identity Center differs from IAM users, and when you'd choose one over the other."**

   *Hint: Identity Center for human access (SSO, short-lived creds, federation-ready, central management). IAM users for service accounts or legacy use cases. IAM roles for service-to-service access. Identity Center has effectively replaced IAM users for human access in modern AWS.*

2. **"How do you handle access to multiple AWS accounts for a team of engineers?"**

   *Hint: AWS Organizations + Identity Center. Define permission sets per role (developer, admin, read-only). Assign users/groups to accounts via permission sets. Federate to external IdP (Okta/Azure AD) if the org has one.*

3. **"What's the security advantage of short-lived credentials over long-lived access keys?"**

   *Hint: Reduced blast radius if leaked. Static keys can be exfiltrated and used indefinitely until manually rotated. Short-lived creds expire automatically. Also: tokens are tied to a specific session and can be revoked instantly.*

4. **"Explain what happens technically when a user runs `aws sso login` and then `aws s3 ls --profile sandcastle`."**

   *Hint: `aws sso login` opens a browser, user authenticates with Identity Center, receives an OIDC token, cached locally. `aws s3 ls --profile sandcastle` reads the profile's `sso_account_id` and `sso_role_name`, calls the SSO endpoint with the cached token to exchange for STS credentials for the matching IAM role, then uses those STS credentials to call S3.*

5. **"How would you enforce that no IAM users with static access keys exist in an account?"**

   *Hint: Service Control Policy (SCP) at the Organizations level denying `iam:CreateAccessKey` and `iam:CreateUser`. AWS Config rule monitoring for IAM users with access keys. Periodic IAM Access Analyzer reports.*

6. **"A permission set has 12-hour session duration. A developer's laptop is stolen mid-session. What's your response?"**

   *Hint: Revoke the SSO session immediately via Identity Center API (`DeleteUser` session) — this invalidates the cached token. Force re-MFA on the user. Investigate CloudTrail for any actions taken during the active session. Consider rotating any data accessed during that window.*

7. **"Why do you have separate permission sets per project even if they currently grant the same level of access?"**

   *Hint: Audit attribution (CloudTrail shows which role/permission set was used), independent evolution (each project can tighten or modify its scope without affecting others), explicit context-switching for the user.*

8. **"What's the difference between Identity Center's built-in directory and external IdP federation?"**

   *Hint: Built-in directory: AWS hosts user accounts; works standalone; good for small teams. External IdP (Okta, Azure AD, Google Workspace): users sourced from existing org IdP; SCIM provisioning syncs groups; group-based permission set assignment; required for most enterprise deployments.*

9. **"If you wanted to add a junior engineer to your AWS environment with read-only access to all projects, how would you do it?"**

   *Hint: Create an Identity Center user for them. Create a `ReadOnlyAccess` permission set using the AWS-managed `ReadOnlyAccess` policy. Assign that user + that permission set to the relevant accounts. They log in with their own credentials; CloudTrail attributes actions to their identity.*

10. **"Describe a real-world IAM-related incident you've read about or could imagine, and how Identity Center would have helped prevent or contain it."**

    *Hint: Capital One 2019 breach (SSRF + over-privileged IAM role). Identity Center wouldn't have prevented the SSRF, but per-permission-set scoping would have reduced the blast radius. Or: leaked GitHub-committed IAM keys (Uber 2016) — Identity Center has no long-lived keys to leak.*

---

## Day 0 Complete

You now have a properly architected AWS access foundation. Every project you build from here uses Identity Center; every CLI command you run uses short-lived credentials; every action you take is attributable in CloudTrail.

**Next**: SandCastle Phase 1 Day 1 — repo scaffolding and Terraform state backend, but now using `--profile sandcastle` from Identity Center.

Don't forget: **set the 4-week reminder to delete `launchpad-dev`**. Future-you will appreciate the cleanup.
