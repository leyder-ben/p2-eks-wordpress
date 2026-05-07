# Multi-Tier Kubernetes Deployment on AWS

WordPress and MySQL deployed to Amazon EKS using Terraform, Helm, and AWS Secrets Manager. Includes persistent database storage, production-grade credential management via the External Secrets Operator, and a Horizontal Pod Autoscaler verified under load.

## Architecture

- **Application:** WordPress connected to a MySQL backend over internal Kubernetes networking
- **Database:** MySQL 8.0 with a 10Gi EBS-backed PersistentVolumeClaim
- **Orchestration:** AWS EKS (Kubernetes 1.31)
- **Infrastructure:** Terraform
- **Package Management:** Helm
- **Secrets:** AWS Secrets Manager + External Secrets Operator
- **Autoscaling:** Horizontal Pod Autoscaler (50% CPU threshold, max 5 replicas)
- **Load Balancer:** AWS ELB provisioned automatically by the WordPress LoadBalancer service

## Prerequisites

Ensure the following tools are installed on your local machine:

- AWS CLI v2
- Terraform >= 1.5.0
- kubectl
- Helm
- Git

AWS credentials must be configured with sufficient permissions for EKS, EC2, IAM, VPC, Secrets Manager, and EBS.

## Infrastructure Setup

### 1. Clone the repository

```bash
git clone https://github.com/leyder-ben/p2-eks-wordpress.git
cd p2-eks-wordpress
```

### 2. Initialize and apply Terraform

```bash
cd terraform
terraform init
terraform apply
```

You will be prompted for two values:

- `db_root_password` — MySQL root password
- `db_wp_password` — WordPress database user password

Terraform will provision:

- VPC with 2 public subnets across 2 availability zones
- EKS cluster (Kubernetes 1.31) with managed node group (t3.medium, 1-4 nodes)
- IAM roles for the cluster, node group, External Secrets Operator, and EBS CSI driver
- OIDC provider for IRSA (IAM Roles for Service Accounts)
- AWS Secrets Manager secret containing all database credentials

Note the outputs when apply completes — you will need the `eso_role_arn` value in a later step.

### 3. Update kubeconfig

```bash
aws eks --region us-east-2 update-kubeconfig --name p2-eks-cluster
kubectl get nodes
```

All nodes should show `STATUS: Ready` before proceeding.

### 4. Verify the EBS CSI Driver

```bash
kubectl get pods -n kube-system | grep ebs
```

All pods should show `Running` before proceeding.

### 5. Install the External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --wait

kubectl get pods -n external-secrets
```

All ESO pods should show `Running` before proceeding.

### 6. Configure the External Secrets Operator

Replace `PASTE_ESO_ROLE_ARN_HERE` with the value from `terraform output eso_role_arn`.

```bash
kubectl apply -f terraform/eso-serviceaccount.yaml
kubectl apply -f terraform/secretstore.yaml
kubectl apply -f terraform/externalsecret.yaml
```

Verify the SecretStore and ExternalSecret are healthy:

```bash
kubectl get secretstore
kubectl get externalsecret
```

`SecretStore` should show `Valid`. `ExternalSecret` should show `SecretSynced`. Confirm the Kubernetes Secret was created:

```bash
kubectl get secret mysql-secret
```

### 7. Deploy MySQL

```bash
kubectl apply -f mysql-pvc.yaml
kubectl apply -f mysql-deployment.yaml
kubectl get pods -w
```

Wait for the MySQL pod to show `Running` and the PVC to show `Bound` before proceeding.

### 8. Install the Metrics Server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl get deployment metrics-server -n kube-system
```

Wait for `1/1 Ready`.

### 9. Deploy WordPress via Helm

```bash
helm install my-microservice ./my-microservice
kubectl get pods -w
```

Wait for the `my-microservice` pod to show `Running`.

### 10. Apply the HPA

```bash
kubectl apply -f hpa.yaml
kubectl get hpa
```

Give it 2 minutes. CPU should show a real percentage rather than `<unknown>`.

## Verify Deployment

```bash
kubectl get svc
```

Copy the `EXTERNAL-IP` from the `my-microservice` LoadBalancer row and open it in a browser. Complete the WordPress installation wizard to initialize the database before running any load tests.

## Load Testing

With WordPress fully installed and connected to MySQL, run a Siege load test to verify the HPA scales under real traffic:

```bash
siege -c 100 -t 5m http://<EXTERNAL-IP>
```

Watch scaling in separate terminals:

```bash
# Terminal 2
kubectl get hpa -w

# Terminal 3
kubectl get pods -w
```

CPU should spike past the 50% threshold and new WordPress pods should scale up automatically.

## Teardown

Delete Kubernetes resources and Helm releases first, then tear down infrastructure with Terraform:

```bash
# Delete Kubernetes resources
kubectl delete all --all
kubectl delete pvc mysql-pvc
kubectl delete secret mysql-secret
kubectl delete externalsecret mysql-externalsecret
kubectl delete secretstore aws-secretstore
kubectl delete serviceaccount eso-sa

# Uninstall Helm releases
helm uninstall my-microservice
helm uninstall external-secrets -n external-secrets

# Remove EBS CSI addon
aws eks delete-addon \
  --cluster-name p2-eks-cluster \
  --addon-name aws-ebs-csi-driver \
  --region us-east-2

# Destroy infrastructure
cd terraform
terraform destroy
```

Terraform will cleanly remove all provisioned resources including the VPC, EKS cluster, node group, IAM roles, and Secrets Manager secret.