# Trend React App — End-to-End Deployment Guide (All-in-one)

> **Goal:** Deploy the already-built React app (inside `dist/`) to AWS using Docker, Terraform (single-file `main.tf`), EKS, and Jenkins CI/CD. The app must be exposed externally on **port 3000**. This README contains every step and every code file you need — ready to copy-paste.

---

## Contents of this README
1. Project structure (what to add)
2. Files included (with full code blocks)
3. Step-by-step commands (build, push, infra, deploy)
4. Jenkins setup & pipeline
5. Monitoring (optional)
6. Teardown & cost control
7. Troubleshooting

---

## 1) Project structure (place these in repo root)
```
Trend/                      # your project folder (you already have dist/)
├─ dist/                     # already built React static files (index.html etc.)
├─ Dockerfile                # provided below
├─ .dockerignore             # below
├─ .gitignore                # below
├─ Jenkinsfile               # pipeline file (below)
├─ k8s/
│  ├─ namespace.yaml
│  ├─ deployment.yaml
│  └─ service.yaml
└─ infra/
   └─ main.tf                # Single-file Terraform (below) - put inside infra/ folder
```

> **Note:** Keep `dist/` in root. The Dockerfile copies `dist/` into nginx image.

---

## 2) Files (copy exactly)

### `Dockerfile`  (USE THIS - you already provided it)
```dockerfile
FROM nginx:alpine
COPY dist/ /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

### `.dockerignore`
```
node_modules
.git
README.md
```

### `.gitignore`
```
node_modules
.DS_Store
.env
```

---

### `infra/main.tf`  (single-file Terraform)
> **Place this file at `infra/main.tf`**. Edit the two clearly marked values at the top: `provider region` and `locals.public_key_path`.

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

# -----------------------------
# 🔹 UPDATE: Change AWS region here if needed
# -----------------------------
provider "aws" {
  region = "ap-south-1"   # <-- CHANGE if you want another region
}

# -----------------------------
# Local values - change public_key_path to your SSH public key
# -----------------------------
locals {
  project = "trend-mini"
  region  = "ap-south-1"

  # 🔹 UPDATE: put path to your SSH public key (Windows: use WSL or full path)
  public_key_path = "~/.ssh/id_rsa.pub"  # <-- CHANGE to your .pub path
}

# -----------------------------
# VPC (2 public subnets)
# -----------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = local.project
  cidr = "10.0.0.0/16"

  azs            = ["${local.region}a", "${local.region}b"]
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = { Project = local.project }
}

# -----------------------------
# EKS Cluster + Node Group
# -----------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.11"

  cluster_name    = "${local.project}-cluster"
  cluster_version = "1.30"

  subnet_ids = module.vpc.public_subnets
  vpc_id     = module.vpc.vpc_id

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]   # 🔹 adjust if needed
      desired_size   = 2
      min_size       = 1
      max_size       = 2
      subnet_ids     = module.vpc.public_subnets
    }
  }

  tags = { Project = local.project }
}

# -----------------------------
# SSH Key Pair (EC2 login)
# -----------------------------
resource "aws_key_pair" "this" {
  key_name   = "${local.project}-kp"
  public_key = file(local.public_key_path)
}

# -----------------------------
# Security Group for Jenkins EC2
# -----------------------------
resource "aws_security_group" "jenkins_sg" {
  name   = "${local.project}-jenkins-sg"
  vpc_id = module.vpc.vpc_id

  ingress { from_port = 22   to_port = 22   protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 8080 to_port = 8080 protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0    to_port = 0    protocol = "-1"  cidr_blocks = ["0.0.0.0/0"] }
}

# -----------------------------
# Jenkins EC2 (t3.micro)
# -----------------------------
data "aws_ami" "al2" {
  most_recent = true
  owners      = ["137112412989"] # Amazon
  filter {
    name   = "name"
    values = ["al2023-ami-kernel-6.*-x86_64"]
  }
}

locals {
  jenkins_userdata = <<-EOF
    #!/bin/bash
    set -e
    yum update -y
    yum install -y docker git unzip
    systemctl enable docker && systemctl start docker
    usermod -aG docker ec2-user

    # Jenkins install
    dnf install -y java-17-amazon-corretto
    curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key | tee /etc/pki/rpm-gpg/RPM-GPG-KEY-jenkins.io-2023
    curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.repo | tee /etc/yum.repos.d/jenkins.repo
    yum install -y jenkins
    systemctl enable jenkins && systemctl start jenkins

    # AWS CLI v2
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    ./aws/install

    # kubectl
    curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

    # helm
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  EOF
}

resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.al2.id
  instance_type               = "t3.micro"
  subnet_id                   = module.vpc.public_subnets[0]
  key_name                    = aws_key_pair.this.key_name
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id]
  associate_public_ip_address = true
  user_data                   = local.jenkins_userdata
  tags = { Name = "${local.project}-jenkins" }
}

# -----------------------------
# Outputs (inline)
# -----------------------------
output "jenkins_public_ip" {
  value       = aws_instance.jenkins.public_ip
  description = "Use this IP to access Jenkins on port 8080"
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}
```

> 🔸 **Important edits (where and what):**
> - `provider "aws"` region — change if you don't want `ap-south-1`.
> - `locals.public_key_path` — point to your SSH public key file (e.g. `~/.ssh/id_rsa.pub`).
> - `eks_managed_node_groups.instance_types` — `t3.small` recommended; change if you want `t3.micro`.

---

### `k8s/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: trend
```

### `k8s/deployment.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trend-web
  namespace: trend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: trend-web
  template:
    metadata:
      labels:
        app: trend-web
    spec:
      containers:
        - name: trend
          image: your_dockerhub_username/trend:latest   # <-- REPLACE this with your DockerHub repo
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet: { path: "/", port: 80 }
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: "/", port: 80 }
            initialDelaySeconds: 15
            periodSeconds: 20
```

### `k8s/service.yaml`  (LoadBalancer exposes port 3000)
```yaml
apiVersion: v1
kind: Service
metadata:
  name: trend-lb
  namespace: trend
  annotations:
    # optional: use NLB instead of ALB (comment/remove if you want default)
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
spec:
  type: LoadBalancer
  selector:
    app: trend-web
  ports:
    - name: http
      port: 3000       # External port (as requested)
      targetPort: 80   # container listens on 80
```

---

### `Jenkinsfile`  (place in repo root)
```groovy
set -e

# Vars
APP_NAME="trend-mini"
DOCKERHUB_USER="yours_id"
DOCKERHUB_PASS="your_password"
IMAGE_FULL="${DOCKERHUB_USER}/${APP_NAME}:latest"
KUBE_NS="default"
KUBE_DEPLOYMENT="trend-mini-app"

echo "[Checkout] already done by SCM step"

echo "[Docker Build]"
docker build -t "${IMAGE_FULL}" .

echo "[Docker Login]"
echo "${DOCKERHUB_PASS}" | docker login -u "${DOCKERHUB_USER}" --password "${DOCKERHUB_PASS}"
echo "[Docker Push]"
docker push "${IMAGE_FULL}"

set -eu

EKS_CLUSTER="trend-mini-cluster"
AWS_REGION="ap-south-1"
KUBECONFIG_FILE="/tmp/kubeconfig_trendmini"

# 0) Make sure proxies won't hijack
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy || true

# 1) Show who we are
echo "[AWS identity]"
aws sts get-caller-identity

# 2) (Important) IGNORE any old kubeconfig; create a fresh, isolated file
rm -f "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"
aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION" --alias trend-mini

# 6) Deploy
echo -e "\n[K8s Deploy]"
kubectl -n "${KUBE_NS}" set image deploy/${KUBE_DEPLOYMENT} ${KUBE_DEPLOYMENT}=${IMAGE_FULL} --record

echo -e "\n[Rollout]"
kubectl -n "${KUBE_NS}" rollout status deploy/${KUBE_DEPLOYMENT} --timeout=5m

echo "[Cleanup]"
docker image prune -f || true

```

---

## 3) Step-by-step commands (exact order)

### A. Local / Preparation
1. Ensure `dist/` is in repo root (already present). Add files listed above.
2. Initialize git and push to GitHub (or fork original repo then push):
```bash
git init
git add .
git commit -m "Add Dockerfile, infra, k8s, Jenkinsfile"
# create remote on GitHub then
git remote add origin git@github.com:YOUR_USER/YOUR_REPO.git
git branch -M main
git push -u origin main
```

3. Build & test Docker locally (optional):
```bash
docker build -t trend:dist .
docker run --rm -p 3000:80 trend:dist
# Visit http://localhost:3000
```

4. Tag & push to Docker Hub (replace username):
```bash
docker tag trend:dist <YOUR_DOCKERHUB_USERNAME>/trend:latest
docker login
docker push <YOUR_DOCKERHUB_USERNAME>/trend:latest
```

### B. Provision infra via Terraform
```bash
cd infra
terraform init
terraform apply -auto-approve
```
Wait until completion. Terraform outputs will include `jenkins_public_ip` and `eks_cluster_name`.

> If terraform fails on public key: make sure `locals.public_key_path` points to an existing `.pub` file.

### C. Configure kubectl locally (optional) or on Jenkins EC2
On **your local machine** (if aws cli configured with same IAM):
```bash
aws eks update-kubeconfig --region ap-south-1 --name trend-mini-app
kubectl get nodes
```

Or, on Jenkins EC2 (recommended for CI): SSH into Jenkins instance and run the same `aws eks update-kubeconfig` after configuring AWS credentials there.

### D. Apply k8s manifests (manual test)
```bash
#kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl get all -n trend
```

Service will show `EXTERNAL-IP` or hostname when LoadBalancer is provisioned. Visit `http://<EXTERNAL-IP or HOSTNAME>:3000`.

### E. Setup Jenkins (on Jenkins EC2)
1. Open `http://<jenkins_public_ip>:8080` in browser.
2. Use `sudo cat /var/lib/jenkins/secrets/initialAdminPassword` to unlock.
3. Install suggested plugins + additionally: **Docker, Docker Pipeline, Git, Kubernetes, Pipeline**.
4. Configure Credentials:
   - **Docker Hub**: Credentials → "Username with password" → ID = `dockerhub-creds`.
   - **AWS**: (Optional) Access Key/Secret if you prefer (or attach an instance role with required permissions).
5. Ensure Docker is available for the `ec2-user` (we added user to docker group in userdata). Test `docker ps` and `kubectl` on Jenkins EC2.

### F. Create Jenkins Pipeline Job
- New Item → Pipeline → SCM: Git → repository URL → Save.
- In the job, select `Jenkinsfile` from repository.
- Run build manually once.
- Configure GitHub webhook for automatic builds (below).

### G. GitHub webhook (auto trigger)
1. In GitHub repo → Settings → Webhooks → Add webhook
   - Payload URL: `http://<jenkins_public_ip>:8080/github-webhook/`
   - Content type: `application/json`
   - Trigger: `Just the push event`.
2. In Jenkins job: Build Triggers → check `GitHub hook trigger for GITScm polling`.

After webhook, every push to repo will trigger Jenkins build → Docker build & push → kubectl deploy.

---

## 4) Monitoring (optional)
**Prometheus + Grafana (via Helm)**
```bash
kubectl create ns monitoring || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kps prometheus-community/kube-prometheus-stack -n monitoring
# port-forward Grafana
kubectl -n monitoring port-forward svc/kps-grafana 3001:80
# open http://localhost:3001
```

> Note: Monitoring stack uses extra resources — uninstall when done.

---

## 5) How to find LoadBalancer DNS & ARN (for submission)
1. Get DNS from Kubernetes:
```bash
kubectl get svc trend-lb -n trend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# OR
kubectl get svc trend-lb -n trend
```
2. Use AWS CLI to find ARN from DNS (replace `<dns>`):
```bash
aws elbv2 describe-load-balancers --region ap-south-1 --query "LoadBalancers[?DNSName=='<dns>'].LoadBalancerArn" --output text
```

---

## 6) Teardown (VERY IMPORTANT — save cost)
1. Delete monitoring (if installed):
```bash
helm uninstall kps -n monitoring
kubectl delete ns monitoring --ignore-not-found
```
2. Delete app resources:
```bash
kubectl delete -f k8s/service.yaml
kubectl delete -f k8s/deployment.yaml
kubectl delete -f k8s/namespace.yaml
```
3. Destroy infrastructure (from infra/):
```bash
cd infra
terraform destroy -auto-approve
```
4. Delete DockerHub repo/images if no longer needed.

---

## 7) Troubleshooting (common issues)
- **Terraform public key error**: Make sure `locals.public_key_path` points to an existing `.pub` file accessible to Terraform.
- **LoadBalancer stuck in Pending**: Ensure subnets are public and tagged (module sets tags). Check `kubectl describe svc trend-lb -n trend` for events.
- **Pods CrashLoop**: `kubectl logs <pod> -n trend` and `kubectl describe pod <pod> -n trend`. Common: wrong image name, missing files in `dist/`.
- **Jenkins cannot push to DockerHub**: Verify `dockerhub-creds` credentials in Jenkins and that `docker login` works on Jenkins EC2.
- **Jenkins cannot access EKS**: Run `aws eks update-kubeconfig --name <cluster-name> --region <region>` on Jenkins EC2 (needs AWS CLI config / credentials or instance IAM role with EKS permissions).

---

## Final Notes & Checklist (Before you run)
- [ ] Replace `your_dockerhub_username` placeholders in `k8s/deployment.yaml` and `Jenkinsfile`.
- [ ] Update `infra/main.tf` provider region & `locals.public_key_path`.
- [ ] Ensure `dist/` is present and contains `index.html`.
- [ ] Keep an eye on costs (EKS + LoadBalancer billing). Always `terraform destroy` when finished.

---

## Done — What I created for you
All necessary files and step-by-step instructions are included above. Copy these files into your repo (structure shown at top), update placeholders, run the commands in **Section 3**, and you'll have a working CI/CD -> EKS deployment exposed on port 3000.

If you want, I can now:
- Generate the actual files inside the repository for you (one-by-one), or
- Provide a shorter checklist & printable PDF, or
- Add sample screenshots placeholders in README for final submission.

Tell me which of the above you want next.

