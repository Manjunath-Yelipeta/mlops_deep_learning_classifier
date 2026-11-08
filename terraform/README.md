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

Attach the AWS-managed `AmazonEC2ContainerRegistryPowerUser` policy to your
GitHub role, or use [`ecr-push-policy.json`](ecr-push-policy.json) for access
restricted to this repository. The ECR repository must already exist.

Run **Actions → AWS connection → Run workflow** on `main`. Each image receives
a unique tag containing the first 7 characters of the commit SHA, run ID, and attempt number. Find the
complete image URI in the run summary. No `latest` tag is overwritten.

The CUDA image can be built on the standard GitHub runner; GPU execution needs
a GPU-enabled host. The current container command keeps the container running
and does not start training or an API.

## EC2 GPU GitHub Actions runner

The workflow now follows the `machulav/ec2-github-runner` start/job/stop pattern:

1. `build-and-push-ecr-image` builds and publishes the image and short commit ID.
2. `launch-runner` starts a Spot `g4dn.xlarge` and registers it with GitHub.
3. `gpu-training` runs on its generated label, pulls the image, and verifies CUDA.
   Replace that check with the training command once a training script is available.
4. `stop-runner` deregisters the runner and terminates EC2 after the GPU job,
   including failed jobs when the instance output is available.

All AWS authentication continues to use the existing OIDC role. No AWS access
keys or EC2 instance profile are needed. Add these repository secrets:

| Secret | Value |
| --- | --- |
| `PERSONAL_ACCESS_TOKEN` | Classic GitHub PAT with `repo` scope, as required by the runner action |
| `AWS_SUBNET_ID_1` | Subnet in us-east-1 with internet access |
| `AWS_SECURITY_GROUP_ID` | Security group in the same VPC; outbound HTTPS/DNS, no inbound rules required |

The subnet must provide outbound connectivity to GitHub, AWS APIs and ECR.
Use a private subnet with NAT, or a public subnet with auto-assign public IPv4
and an internet gateway route. Ensure sufficient Spot G/VT vCPU quota and
capacity. Spot interruptions can end training; save checkpoints externally.

Attach the EC2 permissions from [`ec2-launch-policy.json`](ec2-launch-policy.json)
to the GitHub OIDC role (customer-managed or inline). `AmazonEC2FullAccess` is a
broader managed alternative for EC2 permissions; the SSM `GetParameter` permission
is still needed to resolve the AMI. The account's EC2 Spot service-linked role
must exist before launching Spot instances; create it once through IAM or by
requesting a Spot instance in the console.

The AMI is resolved from AWS's public Ubuntu 26.04 NVIDIA driver base parameter.
The previously supplied `ami-01654480b8a1994bd` was not found in us-east-1.
The disk is 100 GiB encrypted gp3. `pre-runner-script` enables Docker and the
NVIDIA runtime. The current v2 action supports these Ubuntu/bootstrap and disk
options; v2.3.9 does not expose all of them.

Run **AWS connection → Run workflow** on `main`. Each run builds the image and
starts a GPU runner. No training code exists yet, so the current GPU job only
checks CUDA and then cleanup terminates the instance. Do not launch long-running
training detached from this job: cleanup will terminate its host.

If startup fails before the action publishes its instance ID, or cleanup is
interrupted, inspect EC2 for the `mlops-gpu-runner` Name and `GitHubRunId` tags
and terminate any leftover instance. Check repository Settings → Actions →
Runners for a stale registration. Cleanup deletes the root disk; persist results
outside the runner before the GPU job completes.
