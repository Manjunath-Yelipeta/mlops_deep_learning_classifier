# AWS authentication from GitHub Actions

The workflow in [`.github/workflows/aws.yml`](../.github/workflows/aws.yml)
runs on a GitHub-hosted Ubuntu runner. Its first step authenticates to AWS
using OpenID Connect (OIDC), and its second step verifies the assumed identity.

## One-time setup

1. In AWS IAM, configure GitHub's OIDC provider with provider URL
   `https://token.actions.githubusercontent.com` and audience `sts.amazonaws.com`.
2. Create an IAM role that trusts this provider for
   `sts:AssumeRoleWithWebIdentity`. Restrict its trust policy to this GitHub
   repository and the branch you will run the workflow from; require audience
   `sts.amazonaws.com`. Follow the
   [GitHub AWS OIDC setup guide](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
   for the trust policy and subject format appropriate to your repository.
   The current identity check needs no additional AWS service permissions.
   Add only the permissions needed when deployment steps are introduced.
3. In GitHub, open **Settings → Secrets and variables → Actions → Secrets**
   and create these repository secrets:

   | Secret | Value |
   | --- | --- |
   | `AWS_ROLE_ARN` | ARN of the IAM role created above |
   | `AWS_REGION` | AWS region to use, such as `us-east-1` |

4. Commit and push the workflow to the default branch. Open
   **Actions → AWS connection → Run workflow**, selecting a branch allowed
   by the role's trust policy.

A successful run prints the assumed role's account and ARN. This workflow
only checks authentication; it does not provision infrastructure. No long-lived
AWS access keys are needed.
