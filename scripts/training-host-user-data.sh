#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/training-host-bootstrap.log) 2>&1

# The AWS Deep Learning Base GPU AMI supplies Docker, NVIDIA drivers,
# NVIDIA Container Toolkit, AWS CLI, and the SSM agent.
systemctl enable --now docker
nvidia-smi
command -v nvidia-ctk
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

IMAGE_URI='__IMAGE_URI__'
aws ecr get-login-password --region us-east-1 |
  docker login --username AWS --password-stdin 578257748163.dkr.ecr.us-east-1.amazonaws.com
trap 'docker logout 578257748163.dkr.ecr.us-east-1.amazonaws.com' EXIT
docker pull "$IMAGE_URI"
docker run --rm --gpus all "$IMAGE_URI" \
  python -c 'import torch; assert torch.cuda.is_available(), "CUDA is unavailable"; print(torch.cuda.get_device_name(0))'
printf '%s\n' "$IMAGE_URI" > /etc/mlops-training-image
touch /var/lib/mlops-training-ready
echo 'GPU host ready. Start training manually through Session Manager.'
