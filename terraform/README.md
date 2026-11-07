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

4. Commit and push the workflow to the default branch. Open
   **Actions → AWS connection → Run workflow**, selecting a branch allowed
   by the role's trust policy.

A successful run verifies the assumed role, builds the root Dockerfile for
`linux/amd64`, and pushes to
`578257748163.dkr.ecr.us-east-1.amazonaws.com/mlops-deep-learning`.
The region is fixed to `us-east-1` to match this repository; `AWS_REGION` is no
longer required. No long-lived AWS access keys are needed.

## Allow image pushes

Before running, open **IAM → Roles → your GitHub role → Permissions → Add
permissions → Create inline policy → JSON**. Paste
[`ecr-push-policy.json`](ecr-push-policy.json), then create the policy with the
name `PushMlopsImage`. This is a permissions policy, separate from the existing
OIDC trust policy. The ECR repository must already exist.

Run **Actions → AWS connection → Run workflow** on `main`. Each image receives
a unique tag containing the commit SHA, run ID, and attempt number. Find the
complete image URI in the run summary. No `latest` tag is overwritten.

The CUDA image can be built on the standard GitHub runner; GPU execution needs
a GPU-enabled host. The current container command keeps the container running
and does not start training or an API.
