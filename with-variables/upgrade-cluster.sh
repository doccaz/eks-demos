#!/bin/bash

if [ -z $1 ]; then
	echo "Usage: $0 <K8S_VERSION>"
	exit 1
fi
TARGET_VERSION=$1 # e.g., 1.31

echo "Discovering default addon versions for EKS $TARGET_VERSION..."

# Function to get the default version for a specific addon
get_addon_version() {
  aws eks describe-addon-versions \
    --kubernetes-version "$1" \
    --addon-name "$2" \
    --query 'addons[0].addonVersions[?compatibilities[0].defaultVersion==`true`].addonVersion' \
    --output text
}

# Fetch versions and export them as environment variables
export K8S_VERSION="v${TARGET_VERSION}.0"
export EBS_CSI_VERSION=$(get_addon_version "$TARGET_VERSION" "aws-ebs-csi-driver")
export COREDNS_VERSION=$(get_addon_version "$TARGET_VERSION" "coredns")
export KUBE_PROXY_VERSION=$(get_addon_version "$TARGET_VERSION" "kube-proxy")
export VPC_CNI_VERSION=$(get_addon_version "$TARGET_VERSION" "vpc-cni")

# Use envsubst to fill in your cluster template
envsubst < cluster.template.yaml > 3-cluster.yaml

echo "Generated 3-cluster.yaml with discovered versions:"
grep "_VERSION" 3-cluster.yaml

