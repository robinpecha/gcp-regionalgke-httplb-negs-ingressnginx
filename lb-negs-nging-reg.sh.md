# GCP - HTTP LOAD BALANCER > NEGS > REGIONAL GKE CLUSTER > INGRESS-NGINX

Based on https://gist.githubusercontent.com/gabihodoroaga/1289122db3c5d4b6c59a43b8fd659496/raw/85196b969c80dcd89594783a7178db6603a77f43/ingress-nginx-on-gke.md
Thanks to gabihodoroaga

cd GCP/LoadBalancer/lb-negs-nging-reg/
YOURDOMAIN="chimtest1.robinpecha.cz"

## VARS
Replace at least YOURDOMAIN.
```
CLUSTER_NAME="lb-negs-nging-reg"
REGION="europe-west2"
YOURDOMAIN="put-your-domain.here"
echo $CLUSTER_NAME ; echo $REGION ; echo $YOURDOMAIN
```

## Create the cluster
```
gcloud container clusters create $CLUSTER_NAME --region $REGION --machine-type "e2-medium" --enable-ip-alias --num-nodes=2 ; soundalertt
```
time gcloud container clusters create $CLUSTER_NAME --region $REGION --machine-type "e2-medium" --enable-ip-alias --num-nodes=2 ; soundalertt

## add the helm ingress-nginx 
```
helm repo update
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
```

## Install the ingress-nginx
Create a file values.regional.yaml for ingress-nginx:
```
cat << EOF > values.regional.yaml
controller:
  service:
    type: ClusterIP
    annotations:
      cloud.google.com/neg: '{"exposed_ports": {"80":{"name": "ingress-nginx-80-neg"}}}'
EOF
```

And install it:
```
helm install -f values.regional.yaml ingress-nginx ingress-nginx/ingress-nginx ; soundalertt
```

## install dummy web server
Prepare config:
```
cat << EOF > dummy-app-lightweb.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lightweb
spec:
  selector:
    matchLabels:
      app: dummy
  replicas: 3
  template:
    metadata:
      labels:
        app: dummy
    spec:
      containers:
      - name: lightweb
        image: alastairhm/alpine-lighttpd-php
        ports:
        - name: http
          containerPort: 80
        lifecycle:
          postStart:
            exec:
              command: ["/bin/sh", "-c", 'wget https://raw.githubusercontent.com/robinpecha/hello-world/main/php-header/index.php -P /var/www/']
---
apiVersion: v1
kind: Service
metadata:
  name: dummy-service
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: dummy
EOF
```
Apply this config:
```
kubectl apply -f dummy-app-lightweb.yaml ; soundalert
```
Now you can check if is your dummy web server works :
```
kubectl get pods
#  NAME                                        READY   STATUS    RESTARTS   AGE
#  ingress-nginx-controller-???????????-????   1/1     Running   0          5m8s
#  lightweb-???????????-????                   1/1     Running   0          4m35s
#  lightweb-???????????-????                   1/1     Running   0          4m35s
#  lightweb-???????????-????                   1/1     Running   0          4m35s

kubectl port-forward lightweb-???????????-???? 8080:80
#  Forwarding from 127.0.0.1:8080 -> 80
#  Forwarding from [::1]:8080 -> 80

Check in your browser http://localhost:8080

Ctrl+C

```

## Create the ingress object
Prepare config.
Dont forget to point dns record of $YOURDOMAIN to ip shown on end of this tutorial. 
Or simply edit your local hosts file for fake domain:
```
cat << EOF > dummy-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dummy-ingress
  annotations:
    kubernetes.io/ingress.class: "nginx"
spec:
  rules:
  - host: "$YOURDOMAIN"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: dummy-service
            port:
              number: 80
EOF
```
And apply it:
```
kubectl apply -f dummy-ingress.yaml ; soundalert
```

## Find the network tags and zone of ingress
```
NETWORK_TAGS=$(gcloud compute instances list --filter="name=( $(kubectl get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].spec.nodeName}') )" --format="value(tags.items[0])") ; echo $NETWORK_TAGS ; soundalert

NODEZONE=$(gcloud compute instances list --filter="name=( $(kubectl get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].spec.nodeName}') )" --format="value(zone)"); echo $NODEZONE ; soundalert
```

## Configure the firewall
```
gcloud compute firewall-rules create $CLUSTER_NAME-lb-fw --allow tcp:80 --source-ranges 130.211.0.0/22,35.191.0.0/16 --target-tags $NETWORK_TAGS ; soundalert
```
## Add health check configuration
```
gcloud compute health-checks create http app-service-80-health-check --request-path /healthz --port 80 --check-interval 60 --unhealthy-threshold 3 --healthy-threshold 1 --timeout 5 ; soundalert
```

## Add the backend service
```
gcloud compute backend-services create $CLUSTER_NAME-lb-backend --health-checks app-service-80-health-check --port-name http --global --enable-cdn --connection-draining-timeout 300 ; soundalert
```

## Attach our NEG to the backend service
```
gcloud compute backend-services add-backend $CLUSTER_NAME-lb-backend --network-endpoint-group=ingress-nginx-80-neg --network-endpoint-group-zone=$NODEZONE --balancing-mode=RATE --capacity-scaler=1.0 --max-rate-per-endpoint=1.0 --global ; soundalert
```

## Setup the frontend
```
gcloud compute url-maps create $CLUSTER_NAME-url-map --default-service $CLUSTER_NAME-lb-backend ; soundalert
gcloud compute target-http-proxies create $CLUSTER_NAME-http-proxy --url-map $CLUSTER_NAME-url-map ; soundalert
gcloud compute forwarding-rules create $CLUSTER_NAME-forwarding-rule --global --ports 80 --target-http-proxy $CLUSTER_NAME-http-proxy ; soundalert
```

## enable logging
```
gcloud compute backend-services update $CLUSTER_NAME-lb-backend --enable-logging --global ; soundalert
```

## Test
Give it some time to deploy ...
```
IP_ADDRESS=$(gcloud compute forwarding-rules describe $CLUSTER_NAME-forwarding-rule --global --format="value(IPAddress)") ; echo $IP_ADDRESS
curl -s -I http://$IP_ADDRESS/ #404
echo curl -s -I http://$YOURDOMAIN/ #200
```

# cleanup
```
# delete the forwarding-rule aka frontend
gcloud -q compute forwarding-rules delete $CLUSTER_NAME-forwarding-rule --global ; soundalert
# delete the http proxy
gcloud -q compute target-http-proxies delete $CLUSTER_NAME-http-proxy ; soundalert
# delete the url map
gcloud -q compute url-maps delete $CLUSTER_NAME-url-map ; soundalert
# delete the backend
gcloud -q compute backend-services delete $CLUSTER_NAME-lb-backend --global ; soundalert
# delete the health check
gcloud -q compute health-checks delete app-service-80-health-check ; soundalert
# delete the firewall rule
gcloud -q compute firewall-rules delete $CLUSTER_NAME-lb-fw ; soundalert

kubectl delete -f dummy-ingress.yaml ; soundalert
kubectl delete -f dummy-app-lightweb.yaml ; soundalert
helm delete ingress-nginx ; soundalert

# delete the cluster
gcloud -q container clusters delete $CLUSTER_NAME --zone=$ZONE ; soundalertt
# delete the NEG  
gcloud -q compute network-endpoint-groups delete ingress-nginx-80-neg --zone=$REGION-a
gcloud -q compute network-endpoint-groups delete ingress-nginx-80-neg --zone=$REGION-b
gcloud -q compute network-endpoint-groups delete ingress-nginx-80-neg --zone=$REGION-c
gcloud -q compute network-endpoint-groups list
```
