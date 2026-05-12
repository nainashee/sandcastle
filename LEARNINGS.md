# LEARNINGS

Personal reflection log for the SandCastle project. Each entry captures what I worked on, what I learned, what surprised me, and what I'd do differently. Newest entries at the top.

This is intentionally informal — first-person, honest, and includes the things that didn't work. It's a learning artifact for me first, a portfolio supplement second.

---

## 2026-05-11 — Project kickoff and documentation

**What I worked on**:
- Defined SandCastle as a project: personal dev environment on AWS, separated from work laptop
- Wrote the complete documentation set before writing any code: README, architecture, ADRs, cost analysis, security model, runbook
- Settled on the name SandCastle (over CloudDesk, DevForge, NainaLab) — the sandbox metaphor fit naturally

**What I learned**:
- Writing docs first forces real thinking about design. Several design decisions changed mid-document because writing them down exposed weak reasoning.
- ADR format (context → decision → rationale → consequences) is a much better way to capture "why" than scattered comments in code.
- The auto-stop Lambda is the highest-leverage cost optimization in the design — ~73% savings from ~30 lines of Python.

**What surprised me**:
- How much I had to explain about "why no SSH" — this is a real cultural shift from how I'd been thinking about EC2 access. SSM Session Manager is genuinely better in almost every way.
- The cost difference between t3.small and t3.medium is much smaller than I expected once auto-stop is factored in. Made the right-sizing decision much easier.

**What I'd do differently**:
- N/A — this is the start of the project.

**Next session**:
- Phase 1 implementation: scaffold the Terraform repo, write the state backend bootstrap script, build the networking module first.
