PROJECT="some-testing-project"
CLUSTER_NAME="lb-negs-nging-reg"
REGION="europe-west2"
echo $PROJECT ; echo $CLUSTER_NAME ; echo $REGION 

#Create the cluster
gcloud container clusters create $CLUSTER_NAME --region $REGION --machine-type "e2-medium" --enable-ip-alias --num-nodes=2

# add the ingress-nginx repo
helm repo update
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

# create values.regional.yaml with this content:
controller:
  service:
    type: ClusterIP
    annotations:
      cloud.google.com/neg: '{"exposed_ports": {"80":{"name": "ingress-nginx-80-neg"}}}'
      
# and install the ingress-nginx
helm install -f values.regional.yaml ingress-nginx ingress-nginx/ingress-nginx

# Create the dummy app 
# apply the configuration
kubectl apply -f dummy-app-lightweb.yaml

# create the ingress object
# -- give it some time to deploy previous one --
kubectl apply -f dummy-ingress.yaml

# Find the network tags
NETWORK_TAGS=$(gcloud compute instances list --filter="name=( $(kubectl get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].spec.nodeName}') )" --format="value(tags.items[0])") ; echo $NETWORK_TAGS

# Configure the firewall
gcloud compute firewall-rules create $CLUSTER_NAME-lb-fw --allow tcp:80 --source-ranges 130.211.0.0/22,35.191.0.0/16 --target-tags $NETWORK_TAGS

# add health check configuration
gcloud compute health-checks create http app-service-80-health-check --request-path /healthz --port 80 --check-interval 60 --unhealthy-threshold 3 --healthy-threshold 1 --timeout 5

# add the backend service
gcloud compute backend-services create $CLUSTER_NAME-lb-backend --health-checks app-service-80-health-check --port-name http --global --enable-cdn --connection-draining-timeout 300

# add our NEG to the backend service to all zones
gcloud compute backend-services add-backend $CLUSTER_NAME-lb-backend --network-endpoint-group=ingress-nginx-80-neg --network-endpoint-group-zone=$REGION-a --balancing-mode=RATE --capacity-scaler=1.0 --max-rate-per-endpoint=1.0 --global
gcloud compute backend-services add-backend $CLUSTER_NAME-lb-backend --network-endpoint-group=ingress-nginx-80-neg --network-endpoint-group-zone=$REGION-b --balancing-mode=RATE --capacity-scaler=1.0 --max-rate-per-endpoint=1.0 --global
gcloud compute backend-services add-backend $CLUSTER_NAME-lb-backend --network-endpoint-group=ingress-nginx-80-neg --network-endpoint-group-zone=$REGION-c --balancing-mode=RATE --capacity-scaler=1.0 --max-rate-per-endpoint=1.0 --global

# create certificate
CERTIFICATE_NAME="www-ssl-cert" ; echo $CERTIFICATE_NAME
DOMAIN_LIST="yourdomain.com" ; echo $DOMAIN_LIST
gcloud compute ssl-certificates create $CERTIFICATE_NAME --domains=$DOMAIN_LIST --global

# you can check certificate in its status
# gcloud compute ssl-certificates list --global
# gcloud compute ssl-certificates describe $CERTIFICATE_NAME 

# setup the frontend
gcloud compute url-maps create $CLUSTER_NAME-url-map --default-service $CLUSTER_NAME-lb-backend

# setup https proxy
gcloud compute target-https-proxies create $CLUSTER_NAME-http-proxy --url-map $CLUSTER_NAME-url-map --ssl-certificates=$CERTIFICATE_NAME

# setup forwarding rule
gcloud compute forwarding-rules create $CLUSTER_NAME-forwarding-rule --global --ports 443 --target-https-proxy $CLUSTER_NAME-http-proxy

# enable logging
gcloud compute backend-services update $CLUSTER_NAME-lb-backend --enable-logging --global

# Test
IP_ADDRESS=$(gcloud compute forwarding-rules describe $CLUSTER_NAME-forwarding-rule --global --format="value(IPAddress)") ; echo $IP_ADDRESS
curl -s -I https://$IP_ADDRESS/
curl -s -I https://yourdomain.com/


################
# cleanup
# delete the forwarding-rule aka frontend
gcloud -q compute forwarding-rules delete $CLUSTER_NAME-forwarding-rule --global
gcloud -q compute forwarding-rules list
# delete the http proxy
gcloud -q compute target-http-proxies delete $CLUSTER_NAME-http-proxy
gcloud -q compute target-http-proxies list
# delete the url map
gcloud -q compute url-maps delete $CLUSTER_NAME-url-map
gcloud -q compute url-maps list
# delete the backend
gcloud -q compute backend-services delete $CLUSTER_NAME-lb-backend --global
gcloud -q compute backend-services list
# delete the health check
gcloud -q compute health-checks delete app-service-80-health-check
gcloud -q compute health-checks list
# delete the firewall rule
gcloud -q compute firewall-rules delete $CLUSTER_NAME-lb-fw
gcloud -q compute firewall-rules list

kubectl delete -f dummy-ingress.yaml
kubectl delete -f dummy-app-lightweb.yaml
helm delete ingress-nginx

# delete the cluster
gcloud -q container clusters delete $CLUSTER_NAME --zone=$ZONE
gcloud -q container clusters list
# delete the NEG  
gcloud -q compute network-endpoint-groups delete ingress-nginx-80-neg --zone=$REGION-a
gcloud -q compute network-endpoint-groups delete ingress-nginx-80-neg --zone=$REGION-b
gcloud -q compute network-endpoint-groups delete ingress-nginx-80-neg --zone=$REGION-c
gcloud -q compute network-endpoint-groups list
