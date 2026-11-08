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

## Optional GPU EC2 host (AWS CLI)

The workflow can launch one On-Demand GPU instance after the image push.
It uses AWS CLI, with no Terraform state or resources created by Terraform.
`create_ec2` defaults to false so image-only runs keep working.

### One-time AWS setup

1. Create **IAM → Roles → Create role → AWS service → EC2** with role name
   `mlops-training-host`. Attach these AWS-managed policies:
   - `AmazonSSMManagedInstanceCore` for Session Manager access.
   - `AmazonEC2ContainerRegistryReadOnly` for pulling the image.
   Creating the role through the EC2 console wizard creates an instance profile;
   use its **instance profile name**, normally `mlops-training-host`, in the workflow.
   The role trusts EC2, whereas the GitHub role continues to trust GitHub OIDC.
2. Give the GitHub role the permissions in
   [`ec2-launch-policy.json`](ec2-launch-policy.json). You can create a customer-managed
   policy and attach it, or use an inline policy. It permits launches in us-east-1
   and passing only `mlops-training-host`. Update that role ARN if using another
   role name. `AmazonEC2FullAccess` is a broader managed alternative for the EC2
   actions, but does not replace the SSM parameter and `iam:PassRole` permissions.
3. Choose an existing subnet and security group in the same VPC. No inbound rules
   or SSH key pair are needed for Session Manager. Allow outbound HTTPS and DNS.
   A private subnet needs NAT internet access. Alternatively use a public subnet
   with an internet gateway route and enable the workflow's `public_ip` input.
   The host needs access to ECR, S3 image layers, and Systems Manager endpoints.
4. Ensure the account has enough **Running On-Demand G and VT instances** vCPU
   quota (4 for g4dn.xlarge/g5.xlarge, 8 for g5.2xlarge) and capacity in the chosen AZ.

### Run and connect

Run **AWS connection** on `main`, enable `create_ec2`, and fill in `subnet_id`,
`security_group_id`, and `instance_profile`. Choose `g4dn.xlarge` (default),
`g5.xlarge`, or `g5.2xlarge`. The workflow resolves the latest Amazon x86_64
Ubuntu 26.04 NVIDIA driver base AMI from the public SSM parameter and launches
with a 100 GiB encrypted gp3 root disk and IMDSv2 required.

The run summary records the instance ID immediately after launch. The job waits
for EC2's running state, **not for bootstrap completion**. Connect through
**EC2 → Instances → Connect → Session Manager**, then check:

```bash
sudo tail -f /var/log/training-host-bootstrap.log
sudo test -f /var/lib/mlops-training-ready && echo Ready
```

Bootstrap configures the NVIDIA container runtime, pulls this run's image, and
checks CUDA inside the container. It does not start training. Once ready, replace
the example command with your own training entry point:

```bash
IMAGE_URI=$(sudo cat /etc/mlops-training-image)
sudo docker run --rm --gpus all --shm-size=2g "$IMAGE_URI" python YOUR_TRAINING_SCRIPT.py
```

The repository currently contains no training script or dataset. Add those and
mount data/output directories as needed. IMDS is available only on the host;
containers are not given the host's IAM credentials by this setup.

Each new workflow run creates a new billable host. Retries use the same client
token; if the image or resolved AMI changed, AWS rejects the retry with an
idempotency mismatch rather than creating a duplicate. Inspect the earlier
instance before starting a new run. A workflow failure or cancellation does
not terminate an instance already launched. Stop or terminate it in EC2 when
finished; termination deletes its root disk, so save training outputs first.
