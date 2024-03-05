# Is it Observable
<p align="center"><img src="/image/logo.png" width="40%" alt="Is It observable Logo" /></p>

## Episode : Fluentbit vs OpenTelemetry Collector
This repository contains the files utilized during the tutorial presented in the dedicated IsItObservable episode comparing fluentbit and the OpenTelemetry Collector.

this tutorial will also utilize the OpenTelemetry Operator with:
* the OpenTelemetry Demo
* the hipster-shop
* istio
All the observability data generated by the environment would be sent to Dynatrace.

## Prerequisite
The following tools need to be install on your machine :
- jq
- kubectl
- git
- gcloud ( if you are using GKE)
- Helm


### 1.Create a Google Cloud Platform Project
```shell
PROJECT_ID="<your-project-id>"
gcloud services enable container.googleapis.com --project ${PROJECT_ID}
gcloud services enable monitoring.googleapis.com \
cloudtrace.googleapis.com \
clouddebugger.googleapis.com \
cloudprofiler.googleapis.com \
--project ${PROJECT_ID}
```
### 2.Create a GKE cluster
```shell
ZONE=europe-west3-a
NAME=isitobservable-fluentbitcollectorbench
gcloud container clusters create ${NAME} --zone=${ZONE} --machine-type=e2-standard-4 --num-nodes=2
```

## Getting started


### Dynatrace Tenant
#### 1. Dynatrace Tenant - start a trial  
If you don't have any Dynatrace tenant , then I suggest to create a trial using the following link : [Dynatrace Trial](https://dt-url.net/observable-trial)
Once you have your Tenant save the Dynatrace tenant url in the variable `DT_TENANT_URL` (for example : https://dedededfrf.live.dynatrace.com)
```
DT_TENANT_URL=<YOUR TENANT Host>
```

##### 2. Create the Dynatrace API Tokens
The dynatrace operator will require to have several tokens:
* Token to deploy and configure the various components
* Token to ingest metrics and Traces


###### Operator Token
One for the operator having the following scope:
* Create ActiveGate tokens
* Read entities
* Read Settings
* Write Settings
* Access problem and event feed, metrics and topology
* Read configuration
* Write configuration
* Paas integration - installer downloader
<p align="center"><img src="/image/operator_token.png" width="40%" alt="operator token" /></p>

Save the value of the token . We will use it later to store in a k8S secret
```shell
API_TOKEN=<YOUR TOKEN VALUE>
```
###### Ingest data token
Create a Dynatrace token with the following scope:
* Ingest metrics (metrics.ingest)
* Ingest logs (logs.ingest)
* Ingest events (events.ingest)
* Ingest OpenTelemetry
* Read metrics
<p align="center"><img src="/image/data_ingest_token.png" width="40%" alt="data token" /></p>
Save the value of the token . We will use it later to store in a k8S secret

```shell
DATA_INGEST_TOKEN=<YOUR TOKEN VALUE>
```
### Istio

1. Download Istioctl
```shell
curl -L https://istio.io/downloadIstio | sh -
```
This command download the latest version of istio ( in our case istio 1.18.2) compatible with our operating system.
2. Add istioctl to you PATH
```shell
cd istio-1.20.1
```
this directory contains samples with addons . We will refer to it later.
```shell
export PATH=$PWD/bin:$PATH
```

### 4.Clone Github repo
```shell
git clone https://github.com/isItObservable/fluentbitvscollector
cd fluentbitvscollector
```

To run this benchmark and be able to compare fluentbit with the Collector.
I would recommend to :
- create a cluster with one of the 2 solutions 
- run the various tests
- destroy the cluster
- do the same with the other solution

## Fluentbit 

### 0.Deploy most of the components for Fluentbit
The application will deploy the entire environment:
```shell
chmod 777 deployment.sh
TYPE=fluent
./deployment.sh  --clustername "${NAME}" --dturl "${DT_TENANT_URL}" --dtingesttoken "${DATA_INGEST_TOKEN}" --dtoperatortoken "${API_TOKEN}" --agentype "${TYPE}"
```
### 1. Enable remote write on Prometheus
To let fluentbit send the metrics to Prometheus, we need to enalbe the remote write feature on our Prometheus server
To achieve that we need to edit the CRD Prometheus holding the settings of Prometheus and add :
```yaml
enableRemoteWriteReceiver: true
```
edit the Prometheus CRD with the following command:
```shell
 kubectl edit prometheus prometheus-kube-prometheus-prometheus
```
### 2. Run the test collecting logs
```shell
kubectl apply -f fluentbit/fluentbitsvc.yaml -n fluentbit
kubectl delete -f fluentbit/fluent.yaml -n fluentbit
kubectl apply -f fluentbit/pipeline/step1-logs/fluentbit.yaml -n fluentbit
kubectl apply -f fluentbit/fluent.yaml -n fluentbit
```
### 3. Run the test collecting logs and traces
```shell
kubectl delete -f fluentbit/fluent.yaml -n fluentbit
kubectl apply -f fluentbit/pipeline/step2-logs-otlp/fluentbit.yaml -n fluentbit
kubectl apply -f fluentbit/fluent.yaml -n fluentbit
```
### 4. Run the test collecting logs, traces and metrics
```shell
kubectl delete -f fluentbit/fluent.yaml -n fluentbit
kubectl apply -f fluentbit/pipeline/step3-logs-otlp-prometheus/fluentbit.yaml -n fluentbit
kubectl apply -f fluentbit/fluent.yaml -n fluentbit
```
If you are

### Deploy most of the components for The collector
The application will deploy the entire environment:
```shell
chmod 777 deployment.sh
TYPE=collector
./deployment.sh  --clustername "${NAME}" --dturl "${DT_TENANT_URL}" --dtingesttoken "${DATA_INGEST_TOKEN}" --dtoperatortoken "${API_TOKEN}" --agentype="${TYPE}"
```
#### A. with processing at the receiver level
##### 1. Run the test collecting logs
```shell
kubectl apply -f opentelemetry/collector processing after receiving/step1-logs/openTelemetry-manifest_debut.yaml
```
##### 2. Run the test collecting logs and traces
```shell
kubectl apply -f opentelemetry/collector processing after receiving//step2-logs-otlp/openTelemetry-manifest_debut.yaml
```
##### 3. Run the test collecting logs, traces and metrics
```shell
kubectl apply -f opentelemetry/collector processing after receiving/step3-logs-otlp-prometheus/openTelemetry-manifest_debut.yaml
```

#### B. with processing at the processor level
##### 1. Run the test collecting logs
```shell
kubectl apply -f opentelemetry/collector processing at the receiver/step1-logs/openTelemetry-manifest_debut.yaml
```
##### 2. Run the test collecting logs and traces
```shell
kubectl apply -f opentelemetry/collector processing at the receiver/step1-logs/openTelemetry-manifest_debut.yaml
```
##### 3. Run the test collecting logs, traces and metrics
```shell
kubectl apply -f opentelemetry/collector processing at the receiver/step1-logs/openTelemetry-manifest_debut.yaml
```
#### C. using the targetAllocator for metrics

#### Create a Collector with the target Allocator
```shell
kubectl apply -f istio/podmonitor.yaml
kubectl apply -f kepler/serviceMonitor.yaml -n kepler
kubectl apply -f  opentelemetry/targetallocator/openTelemetry-manifest_debut.yaml
kubectl apply -f opentelemetry/targetallocator/openTelemetry-manifest_statefulset.yaml
```