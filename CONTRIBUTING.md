# Contributing

We happily welcome contributions to this project. We use GitHub Issues to track community reported issues and GitHub Pull Requests for accepting changes pursuant to a CLA.

This project is maintained by Databricks Field Engineering. To report a bug, ask a question, or suggest an improvement, please open a GitHub Issue on this repository.

## Guidelines

- **No customer data.** Do not include customer data, personally identifiable information (PII), proprietary information, credentials, tokens, workspace URLs, or workspace/resource ids in issues, pull requests, commits, or attachments. The seed data in this repository is synthetic sample data; keep it that way.
- Keep changes focused, and describe what changed and how you verified it in the pull request.
- Run the local SQL validation before submitting changes to the pipeline SQL:

  ```bash
  python sql/mef_volume/validate_local.py
  ```

- Security issues should not be filed as GitHub Issues. See [SECURITY.md](SECURITY.md).
