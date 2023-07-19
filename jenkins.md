# Jenkins Deployment Instructions

- [Configure the environment to use EFS](#configure_the_environment_to_use_efs)
- [Install Jenkins using Helm](#install_jenkins_using_helm)
- [Access the Jenkins UI](#access_the_jenkins_ui)
- [Do some dangerous clustery things](#allow_all_service_accounts_to_act_as_cluster_administrators)

## Configure the environment to use EFS

The environment should be configured to use EFS for persistent storage in order to tolerate a node failure.

### Create service accounts and AWS EFS CSI driver

- Create 2 service accounts `efs-csi-controller-sa` and `efs-csi-node-sa`, a cluster role `clusterrole.rbac.authorization.k8s.io/efs-csi-external-provisioner-role`, a cluster role binding `clusterrolebinding.rbac.authorization.k8s.io/efs-csi-provisioner-binding`, a deployment `deployment.apps/efs-csi-controller`, a daemonset `daemonset.apps/efs-csi-node`, and configure `csidriver.storage.k8s.io/efs.csi.aws.com` by performing the following command:

```go
./kubectl apply -k "github.com/kubernetes-sigs/aws-efs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"
```

### Create the Kubernetes EFS resources

```go
./kubectl apply -f storageclass.yaml,persistentvolume.yaml,persistentvolumeclaim.yaml
```

## Install Jenkins using Helm

### Add the Helm repository for Jenkins

```go
./helm repo add jenkins https://charts.jenkins.io
```

### Update the Helm repositories

```go
./helm repo update
```

### Provision Jenkins

```go
./helm install jenkins jenkins/jenkins --set rbac.create=true,controller.servicePort=80,controller.serviceType=LoadBalancer,persistence.existingClaim=efs-claim
```

## Access the Jenkins UI

### Print the load balancer name

- For Linux:
```bash
printf $(kubectl get service jenkins -o jsonpath="{.status.loadBalancer.ingress[].hostname}");echo
```
- For Windows:
```ps
$jenkinsLoadBalancer = .\kubectl get service jenkins -o jsonpath="{.status.loadBalancer.ingress[].hostname}"
echo $jenkinsLoadBalancer
```

### Print the Jenkins password

- For Linux:
```go
printf $(kubectl get secret --namespace default jenkins -o jsonpath="{.data.jenkins-admin-password}" | base64 --decode);echo
```
- For Windows:
```ps
$jenkinsAdminPassword = .\kubectl get secret --namespace default jenkins -o jsonpath="{.data.jenkins-admin-password}" | ForEach-Object { $passwordBytes = [System.Convert]::FromBase64String($_); [System.Text.Encoding]::UTF8.GetString($passwordBytes) }
echo $jenkinsAdminPassword
```

## Allow all service accounts to act as cluster administrators

Any application running in a container receives service account credentials automatically, and could perform any action against the API, including viewing secrets and modifying permissions. This is not a recommended policy and has no impact on the functionality of the Jenkins deployment. This was a requirement outlined in the technical task instructions.

```go
./kubectl create clusterrolebinding permissive-binding --clusterrole=cluster-admin --user=admin --user=kubelet --group=system:serviceaccounts
```