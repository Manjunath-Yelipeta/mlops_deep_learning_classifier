#!/usr/bin/env bash
set -euo pipefail

: "${SUBNET_ID:?Provide subnet_id}"
: "${SECURITY_GROUP_ID:?Provide security_group_id}"
: "${INSTANCE_PROFILE:?Provide instance_profile}"
: "${IMAGE_URI:?Missing built image URI}"
: "${INSTANCE_TYPE:?Provide instance_type}"
: "${GITHUB_RUN_ID:?Missing workflow run ID}"
: "${GITHUB_REPOSITORY_ID:?Missing repository ID}"
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

case "$INSTANCE_TYPE" in
  g4dn.xlarge|g5.xlarge|g5.2xlarge) ;;
  *) echo "Unsupported GPU instance type" >&2; exit 1 ;;
esac
[[ "$SUBNET_ID" =~ ^subnet-[0-9a-f]+$ ]] || { echo "Invalid subnet ID" >&2; exit 1; }
[[ "$SECURITY_GROUP_ID" =~ ^sg-[0-9a-f]+$ ]] || { echo "Invalid security group ID" >&2; exit 1; }
[[ "$INSTANCE_PROFILE" =~ ^[A-Za-z0-9_+=,.@-]+$ ]] || { echo "Invalid instance profile name" >&2; exit 1; }
[[ "$IMAGE_URI" =~ ^578257748163\.dkr\.ecr\.us-east-1\.amazonaws\.com/mlops-deep-learning:[A-Za-z0-9_.-]+$ ]] || { echo "Invalid image URI" >&2; exit 1; }

subnet_vpc=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].VpcId' --output text)
sg_vpc=$(aws ec2 describe-security-groups --group-ids "$SECURITY_GROUP_ID" --query 'SecurityGroups[0].VpcId' --output text)
[[ "$subnet_vpc" == "$sg_vpc" ]] || { echo "Subnet and security group must use the same VPC" >&2; exit 1; }

export AMI_ID
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-26.04/latest/ami-id \
  --query Parameter.Value --output text)
export ROOT_DEVICE
ROOT_DEVICE=$(aws ec2 describe-images --image-ids "$AMI_ID" --owners amazon \
  --filters Name=state,Values=available Name=architecture,Values=x86_64 \
  --query 'Images[0].RootDeviceName' --output text)
[[ "$ROOT_DEVICE" != None && -n "$ROOT_DEVICE" ]] || { echo "Invalid GPU AMI" >&2; exit 1; }

request_file=$(mktemp)
trap 'rm -f "$request_file"' EXIT
python3 - "$request_file" <<'PY'
import base64
import json
import os
import pathlib
import sys

e = os.environ
bootstrap = pathlib.Path('scripts/training-host-user-data.sh').read_text()
# IMAGE_URI is restricted to a literal ECR URI above.
bootstrap = bootstrap.replace('__IMAGE_URI__', e['IMAGE_URI'])
request = {
    'ImageId': e['AMI_ID'], 'InstanceType': e['INSTANCE_TYPE'],
    'MinCount': 1, 'MaxCount': 1,
    # Re-running this workflow run reuses its launch request, rather than
    # launching another billable instance. A new run creates a new host.
    'ClientToken': f"training-{e['GITHUB_REPOSITORY_ID']}-{e['GITHUB_RUN_ID']}",
    'IamInstanceProfile': {'Name': e['INSTANCE_PROFILE']},
    'NetworkInterfaces': [{
        'DeviceIndex': 0, 'SubnetId': e['SUBNET_ID'],
        'Groups': [e['SECURITY_GROUP_ID']],
        'AssociatePublicIpAddress': e.get('PUBLIC_IP') == 'true',
        'DeleteOnTermination': True,
    }],
    'MetadataOptions': {'HttpTokens': 'required', 'HttpEndpoint': 'enabled',
                        'HttpPutResponseHopLimit': 1},
    'BlockDeviceMappings': [{
        'DeviceName': e['ROOT_DEVICE'],
        'Ebs': {'VolumeSize': 100, 'VolumeType': 'gp3',
                'Encrypted': True, 'DeleteOnTermination': True},
    }],
    'UserData': base64.b64encode(bootstrap.encode()).decode(),
    'TagSpecifications': [{
        'ResourceType': resource,
        'Tags': [{'Key': 'Name', 'Value': 'mlops-training'},
                 {'Key': 'ManagedBy', 'Value': 'github-actions'},
                 {'Key': 'GitHubRunId', 'Value': e['GITHUB_RUN_ID']}],
    } for resource in ['instance', 'volume']],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(request))
PY

instance_id=$(aws ec2 run-instances --cli-input-json "file://$request_file" \
  --query 'Instances[0].InstanceId' --output text)
# Record the ID before waiting, so it remains visible if the waiter fails.
echo "Created training host: $instance_id"
{
  echo "### GPU training host"
  echo "Instance: \`$instance_id\` (us-east-1)"
  echo "Image: \`$IMAGE_URI\`"
  echo "Connect: EC2 console → instance → Connect → Session Manager."
  echo "Bootstrap is asynchronous. Check /var/log/training-host-bootstrap.log."
  echo "The instance stays running; stop or terminate it when finished."
} >> "$GITHUB_STEP_SUMMARY"
aws ec2 wait instance-running --instance-ids "$instance_id"
