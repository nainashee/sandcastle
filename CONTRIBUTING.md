# Contributing to SandCastle

SandCastle is primarily a personal portfolio and learning project, but contributions, issues, and suggestions are welcome.

## Reporting Issues

If you spot a bug in the code or an error in the documentation, please open a GitHub issue with:

- **What you observed** vs. **what you expected**
- **Steps to reproduce** (if applicable)
- **Environment details** (Terraform version, AWS region, etc.)

For documentation issues, even small ones like typos are worth raising — clarity matters for a project whose purpose is teaching.

## Suggesting Improvements

If you have ideas for how SandCastle could be improved (better architecture, missing security controls, additional learning material), open an issue tagged `enhancement`. I'll respond and we can discuss before any code is written.

## Pull Requests

If you'd like to contribute a fix or improvement directly:

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-change`
3. Make your changes, including tests/validation where applicable
4. Ensure pre-commit hooks pass: `pre-commit run --all-files`
5. Commit with a clear message describing the change
6. Push to your fork and open a pull request

PRs should:
- Have a clear description of what changes and why
- Include or update documentation for any user-facing changes
- Pass `terraform fmt`, `terraform validate`, and `tflint`
- Not introduce hardcoded secrets, account IDs (other than `989126024881` in examples), or personal information

## Documentation Style

SandCastle's documentation emphasizes the *why* behind decisions, not just the *what*. When adding or editing docs:

- Lead with motivation/context
- Show working examples
- Explain trade-offs honestly
- Avoid AWS marketing language

## Code of Conduct

Be respectful. This is a personal learning project; engage in good faith.

## Questions

If you're a fellow learner with questions about anything in this repo, feel free to open a discussion or reach out via my profile at [hussainashfaque.com](https://hussainashfaque.com).
