# Multi-Tier Kubernetes Deployment on AWS
### Terraform · MySQL · Wordpress · AWS Secrets Manager · Horizontal Pod Autoscaler 

**Ben Leyder | Cloud Infrastructure**

---

## Overview

This project started as a manually provisioned single-pod deployment — functional, but not something you'd put in front of a real workload. The rebuild replaced every manual step with infrastructure-as-code, added a proper database tier, handled credentials the way production teams actually handle them, and load tested the result with real autoscaling events to prove the setup worked under pressure.

The stack: an EKS cluster built entirely with Terraform, MySQL backed by persistent EBS storage, WordPress deployed via Helm, credentials managed through AWS Secrets Manager with the External Secrets Operator syncing them into the cluster, and a Horizontal Pod Autoscaler that scaled WordPress pods in real time under a 100-user Siege load test.

Three things made this rebuild meaningfully different from v1:

- **Infrastructure as code** — Terraform provisioned the VPC, subnets, IAM roles, EKS cluster, node group, and Secrets Manager secret. No console clicks, no eksctl, no manual steps that can't be repeated.
- **Secrets are handled properly** — AWS Secrets Manager holds the database credentials. The External Secrets Operator pulls them into a Kubernetes Secret automatically on a refresh interval. Rotating credentials in Secrets Manager updates the cluster without touching the deployment.
- **The HPA targets the right deployment from the start** — a name mismatch from the original session was corrected before the first apply. The autoscaler was wired correctly and triggered under real load.

---

## Repository Structure

```
p2-eks-wordpress/
├── terraform/
│   ├── main.tf              # VPC, EKS cluster, IAM roles, Secrets Manager
│   ├── providers.tf         # AWS provider configuration
│   ├── variables.tf         # Input variables
│   ├── outputs.tf           # Cluster endpoint, ESO role ARN, secret ARN
│   ├── eso-serviceaccount.yaml  # ESO service account with IAM role annotation
│   ├── secretstore.yaml     # SecretStore — points ESO at AWS Secrets Manager
│   └── externalsecret.yaml  # ExternalSecret — maps secret keys into Kubernetes
├── my-microservice/         # Helm chart for WordPress
│   ├── values.yaml          # Image, service type, resources, env vars, DB config
│   └── templates/
│       └── deployment.yaml  # Patched to pass env block to container
├── mysql-deployment.yaml    # MySQL deployment + ClusterIP service
├── mysql-pvc.yaml           # 10Gi EBS-backed PersistentVolumeClaim
├── hpa.yaml                 # HorizontalPodAutoscaler — 50% CPU threshold
└── WRITEUP.md
```

---

## Environment

| | |
|---|---|
| **OS** | Windows PC with WSL Ubuntu |
| **Terminal** | Git Bash / WSL |
| **AWS Region** | us-east-2 (Ohio) |
| **Cluster Name** | p2-eks-cluster |
| **Node Type** | t3.medium |
| **Node Count** | 2 desired / 1 min / 4 max |
| **Terraform Version** | v1.15.2 |
| **EKS Version** | Kubernetes 1.31 |

---

## Architecture

Terraform owns the bottom half of the stack — VPC, subnets, IAM roles, OIDC provider, EKS cluster, node group, and the Secrets Manager secret. Helm owns the top half — MySQL deployment, WordPress deployment, services, and HPA. AWS Secrets Manager sits in the middle: Terraform creates it, and the External Secrets Operator watches for ExternalSecret objects and pulls the credential values down into a Kubernetes Secret that WordPress reads at startup via environment variables.

> Terraform pours the foundation and frames the walls. Helm hangs the doors and turns on the lights. Secrets Manager is the lockbox bolted to the wall that nobody can read unless they have the right IAM key.

| Component | Managed By | What It Does |
|---|---|---|
| VPC | Terraform | Custom VPC, 2 public subnets across 2 AZs, public IP auto-assignment enabled |
| EKS Cluster | Terraform | p2-eks-cluster, managed node group, Kubernetes 1.31, vpc-cni installed before nodes |
| IAM Roles | Terraform | Cluster role, node role, OIDC provider, ESO role, EBS CSI driver role |
| AWS Secrets Manager | Terraform | Stores MySQL root password, WordPress DB password, username, and database name |
| External Secrets Operator | Helm | Syncs Secrets Manager values into a Kubernetes Secret on a 1-hour refresh interval |
| MySQL Deployment | Helm/YAML | Single pod, MySQL 8.0, reads credentials from Kubernetes Secret via env vars |
| MySQL PVC | YAML | 10Gi EBS volume backed by gp2 StorageClass — data survives pod restarts |
| MySQL ClusterIP Service | YAML | Internal-only — WordPress reaches MySQL through this service name |
| WordPress Deployment | Helm | Single pod baseline, scales via HPA, reads DB credentials from Secret |
| WordPress LoadBalancer | Helm | Exposes WordPress to the internet via AWS ELB |
| HPA | YAML | Scales WordPress pods when CPU exceeds 50%, max 5 replicas |
| Siege | WSL | Load generator — 100 concurrent users, 5 minutes |

---

## Load Test Results

Siege ran 100 concurrent users for 5 minutes against the WordPress LoadBalancer endpoint. WordPress was fully connected to MySQL at test time, so each request triggered real database queries rather than hitting a cached static page.

| Metric | Result |
|---|---|
| **Successful Transactions** | 2,095 |
| **Availability** | 94.41% |
| **Failed Transactions** | 124 |
| **Peak CPU Usage** | 127% (well above 50% HPA threshold) |
| **Replicas at Peak** | 3 (scaled from 1) |
| **Time to First Scale Event** | ~1 minute after Siege started |
| **Scale-Down After Load** | Returned to 1 replica within 5 minutes |
| **Data Transferred** | 13.65 MB |
| **Peak Concurrency** | 93.13 of 100 users active |

The HPA scaled WordPress from 1 pod to 3 pods within about a minute of Siege starting. CPU spiked to 127% on the initial pod — well past the 50% threshold. New pods went from Pending to Running in roughly one second. After the load test finished, the HPA held the extra replicas for the default 5-minute cooldown before scaling back to 1.

---

## Troubleshooting Log

Nine issues came up during the build. Every one of them is documented below — what happened, what fixed it, and why it broke in the first place. This is where the real learning lives.

---

### #1 — Node Group CREATE_FAILED: Subnet Public IP Not Enabled

The first `terraform apply` built the VPC and started the EKS cluster, but the node group failed with `Ec2SubnetInvalidConfiguration`. AWS was rejecting the subnets because auto-assign public IP wasn't turned on. Nodes launched into those subnets had no public IP and couldn't communicate with the EKS control plane, so they never joined the cluster.

**Fix:** Added `map_public_ip_on_launch = true` to the VPC module block in `main.tf`. Ran `terraform destroy` and re-applied clean.

**Root cause:** The `terraform-aws-modules` VPC module doesn't enable public IP auto-assignment by default — it has to be set explicitly.

---

### #2 — SecretStore Failed: API Version v1beta1 No Longer Exists

Applying the SecretStore manifest failed immediately with `no matches for kind SecretStore in version external-secrets.io/v1beta1`. The game plan was written against an older version of the External Secrets Operator. The installed version had promoted the CRDs from `v1beta1` to `v1`.

**Fix:** Ran `kubectl api-resources | grep external-secrets` to confirm the correct API version, then updated the `apiVersion` field in both `secretstore.yaml` and `externalsecret.yaml` from `v1beta1` to `v1`.

**Root cause:** ESO promoted their CRDs from v1beta1 to v1 in newer releases. The version in the manifest and the version installed on the cluster have to match exactly.

---

### #3 — PVC and MySQL Pod Stuck in Pending

After deploying MySQL, both the PVC and the pod sat in Pending for over seven minutes without moving. The PVC had no `storageClassName` set, so Kubernetes had no provisioner to request a volume from. The cluster's `WaitForFirstConsumer` binding mode made it worse — the PVC wouldn't provision until a pod was scheduled, and the pod wouldn't schedule until the PVC bound. They were deadlocked waiting on each other.

**Fix:** Added `storageClassName: gp2` to the PVC spec to explicitly reference the cluster's EBS provisioner.

**Root cause:** Without an explicit storageClassName the PVC had no provisioner to call. Combined with WaitForFirstConsumer, the PVC and pod were stuck in a loop.

---

### #4 — PVC Still Pending: EBS CSI Driver Not Installed

Even after adding the storageClassName, the PVC wouldn't bind. Running `kubectl describe pvc` showed Kubernetes waiting on the `ebs.csi.aws.com` provisioner which wasn't installed. EKS 1.21 and later moved away from the in-tree EBS provisioner to the EBS CSI driver, which has to be added separately as a cluster addon.

**Fix:** Installed the `aws-ebs-csi-driver` addon via the AWS CLI.

**Root cause:** Newer EKS clusters expect the EBS CSI driver to be present. The gp2 StorageClass points to it but the driver itself isn't bundled with the cluster — it's an optional addon.

---

### #5 — EBS CSI Controller CrashLoopBackOff: IAM Permissions

After installing the addon, the two controller pods immediately went into CrashLoopBackOff. The logs showed `UnauthorizedOperation` on `ec2:DescribeAvailabilityZones`. The controller was running under the node IAM role, which had no EC2 API permissions. The EBS CSI driver needs its own dedicated IAM role.

**Fix:** Added an IRSA-backed IAM role to `main.tf` with the `AmazonEBSCSIDriverPolicy` managed policy attached, bound to the `ebs-csi-controller-sa` service account in kube-system. Applied it with Terraform, then deleted and recreated the addon with the role ARN attached from the start. The addon was stuck in CREATING and couldn't be updated in that state — it had to be deleted and recreated.

**Root cause:** The EBS CSI driver requires its own IAM role with EC2 and EBS permissions. It cannot inherit those permissions from the node group role.

---

### #6 — Helm Install Failed: nil pointer serviceAccount

The first `helm install` failed with a nil pointer error on `serviceAccount.create`. When `values.yaml` was replaced with the WordPress configuration, the `serviceAccount` block from the default Helm scaffold was stripped out. The serviceaccount template in the chart still expected that block to exist.

**Fix:** Added `serviceAccount: create: false` back to `values.yaml`.

**Root cause:** Replacing the entire values file removes blocks that the default chart templates depend on. Each template has to have its required values present even if the feature is disabled.

---

### #7 — Helm Install Failed: nil pointer httpRoute

Immediately after fixing the serviceAccount error, `helm install` failed again with the same nil pointer error on `httpRoute.enabled`. Newer versions of the Helm scaffold include an httproute template that wasn't in the game plan's expected default chart structure.

**Fix:** Added `httpRoute: enabled: false` to `values.yaml`.

**Root cause:** The Helm scaffold evolves between versions. Templates added in newer scaffold versions expect matching values entries that older game plans don't account for.

---

### #8 — MySQL Rejecting All Credentials

WordPress showed "Error establishing database connection" in the browser. Direct exec commands into the MySQL pod returned Access Denied for both root and wordpress_user with the correct passwords. MySQL had initialized its data directory during a previous failed deployment attempt with different or empty credentials. Once that data is written to the PVC, MySQL locks in those credentials — the correct values from Secrets Manager don't matter because MySQL already initialized with something else.

**Fix:** Deleted the MySQL deployment and PVC to wipe the data directory completely. Redeployed so MySQL could reinitialize from scratch using the correct credentials from the Kubernetes Secret.

**Root cause:** MySQL writes credentials into the data directory on first startup. If the PVC survives a pod failure and gets reused, the new pod inherits whatever credentials the old pod initialized with — not the current secret values.

---

### #9 — WordPress Pod OOMKilled Under Siege Load

During the first Siege run, the WordPress pod was killed with OOMKilled status before CPU could build up enough to trigger the HPA. The 512Mi memory limit was too tight for WordPress handling 100 concurrent users with active database queries running. The pod died before it could scale.

**Fix:** Increased the memory limit to 768Mi and the request to 384Mi in `values.yaml`, then ran `helm upgrade` to apply the change without tearing down the deployment. The second Siege run completed successfully with the HPA scaling to 3 replicas.

**Root cause:** 512Mi is too tight for WordPress under real concurrent load. PHP processes and active database connection pooling need more headroom than a baseline idle pod requires.

---

## What This Project Demonstrates

- **Multi-tier architecture** — two separate deployments communicating over internal Kubernetes networking, with MySQL isolated behind a ClusterIP service that nothing external can reach directly
- **Infrastructure as code from the ground up** — Terraform manages the full infrastructure layer with no console clicks or manual steps
- **Production-grade secrets management** — AWS Secrets Manager stores credentials, the External Secrets Operator syncs them into the cluster automatically on a refresh interval
- **Working autoscaling with real numbers** — CPU hit 127% under load, the HPA scaled from 1 to 3 pods in under a minute, and the system returned to baseline after load dropped
- **Nine documented troubleshooting events** — subnet configuration, API version changes, CSI driver IAM permissions, Helm scaffold issues, credential initialization, and memory limits — each diagnosed from first principles and resolved cleanly
- **Version controlled from day one** — all Terraform configs, Helm chart, and Kubernetes manifests committed to GitHub before the first apply

---

*github.com/leyder-ben/p2-eks-wordpress*