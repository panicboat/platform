# kubernetes-clusters

## minikube

```sh
minikube start --driver=podman --network-plugin=cni --cni=calico --kubernetes-version=v1.32.0
# Prometheus
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/prometheus
kubectl expose service prometheus-server --type=NodePort --target-port=9090 --name=prometheus-server-np
kubectl get svc
# Grafana
helm repo add grafana https://grafana.github.io/helm-charts
helm install grafana grafana/grafana
kubectl expose service grafana --type=NodePort --target-port=3000 --name=grafana-np
kubectl get secret --namespace default grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
```

The following must be modified before `kustomize build`.
- [Artifact Repository](argo-workflows/applications/default/configmap/artifact-repositories.yaml)
- [AWS CREDENTIAL](argo-workflows/applications/default/secret/aws-credentials.yaml)

```sh
kustomize build . | kubectl apply -f -
```

[Prometheus and Grafana setup in Minikube](https://brain2life.hashnode.dev/prometheus-and-grafana-setup-in-minikube)

### Prometheus

```sh
minikube service prometheus-server-np --url
```

### Grafana

```sh
minikube service grafana-np --url
```

### Argo Workflows

```sh
kubectl -n argo port-forward deployment/argo-server 2746:2746
```
https://127.0.0.1:2746

### Argo Events

```sh
kubectl port-forward $(kubectl get pod -l eventsource-name=webhook -o name) 12000:12000
```

#### Metrics

```sh
kubectl -n argo port-forward deploy/workflow-controller 9090:9090
kubectl -n argo-events port-forward deploy/controller-manager 7777:7777
```
http://127.0.0.1:9090/metrics
http://127.0.0.1:7777/metrics
