#!/bin/bash

ROOT=$(git rev-parse --show-toplevel)/demo-scripts

if ! source "$ROOT"/helpers/init.sh; then exit 1; fi

source "$ROOT"/helpers/functions.sh >/dev/null

echo "Parsing yaml's"
source "$ROOT"/helpers/parser.sh >/dev/null

export REPO_MP="docker.io/cmwylie19"
export clusterNumber=${MP_CLUSTER}
export clusterlabel="tsb-mp-cp"

DNS_RECORD_TYPE="CNAME"

echo "Connecting to the Management Plane cluster"

if ! connectToCluster "${clusterNumber}"; then
    echo "Can't connect to the cluster Exiting!"
    exit 1
else
    echo "Succesfully connected to the ${CLUSTER_LIST[$clusterNumber]}"
fi

installCertManager
OCP_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath={.spec.domain})

kubectl wait -n openshift-cert-manager --for=condition=Available --timeout=4m deployment/cert-manager-webhook 2>/dev/null

if ! kubectl -n "$TSB_NS" rollout status deployment/tsb-operator-management-plane 2>/dev/null; then
    tctl install manifest management-plane-operator \
    --registry "$REPO_MP" >/tmp/managementplaneoperator.yaml
    kubectl apply -f /tmp/managementplaneoperator.yaml
    kubectl wait -n "$TSB_NS" --for=condition=Available --timeout=4m deployment/tsb-operator-management-plane 2>/dev/null
else
    echo "TSB MP Operator deployment already exists"
fi

if ! kubectl -n "$TSB_NS" rollout status deployment/envoy 2>/dev/null; then
    kubectl apply -f /tmp/cert-manager.yaml
    # kubectl wait -n "$TSB_NS" --for=condition=Ready --timeout=10m certificate/tsb-certs 2>/dev/null
    

    echo "Install an OperatorGroup to tsb namespace"
    eval "echo \"$(cat "$ROOT"/templates/tsb-og.yaml)\"" > /tmp/tsb-og.yaml
    kubectl apply --validate=false -f /tmp/tsb-og.yaml

    echo "Install Postgres Operator"
    eval "echo \"$(cat "$ROOT"/templates/pg-sub.yaml)\"" > /tmp/pg-sub.yaml
    kubectl apply --validate=false -f /tmp/pg-sub.yaml
    sleep 30
    kubectl wait -n "$TSB_NS" --for=condition=Available --timeout=4m deployment/pgo
    
    echo "Install Postgres CR"
    eval "echo \"$(cat "$ROOT"/templates/pg-cr.yaml)\"" > /tmp/pg-cr.yaml
    kubectl apply --validate=false -f /tmp/pg-cr.yaml
    sleep 30
    kubectl wait -n "$TSB_NS" --for=condition=PGBackRestRepoHostReady --timeout=4m postgrescluster/tsb 2>/dev/null
    
    echo "Install ElasticSearch Operator"
    eval "echo \"$(cat "$ROOT"/templates/es-sub.yaml)\"" > /tmp/es-sub.yaml
    kubectl apply --validate=false -f /tmp/es-sub.yaml
    sleep 30
    kubectl wait -n "$TSB_NS" --for=condition=Available --timeout=4m deployment/elastic-operator 2>/dev/null
    
    echo "Install ElasticSearch & Kibana CR"
    eval "echo \"$(cat "$ROOT"/templates/eck.yaml)\"" > /tmp/eck.yaml
    kubectl apply --validate=false -f /tmp/eck.yaml
    sleep 30
    kubectl wait -n "$TSB_NS" --for=condition=ReconciliationComplete --timeout=4m elasticsearch/tsb 2>/dev/null
    kubectl wait -n "$TSB_NS" --for=condition=Available --timeout=4m deploy/tsb-kb 2>/dev/null

    echo "Create Network Policy for Elasticsearch"
    eval "echo \"$(cat "$ROOT"/templates/es-network-policy.yaml)\"" >/tmp/es-network-policy.yaml
    kubectl apply -f /tmp/es-network-policy.yaml 2>/dev/null

    eval "echo \"$(cat "$ROOT"/templates/mgmntplane-cr-base.yaml)\"" >/tmp/mgmntplane-cr.yaml

    kubectl get secret -n tsb tsb-es-http-certs-public -o go-template='{{ index .data "ca.crt" | base64decode }}' >/tmp/es-ca.crt

    kubectl -n tsb create secret generic es-certs --from-file=ca.crt=/tmp/es-ca.crt

    tctl install manifest management-plane-secrets \
    --elastic-password $(kubectl -n tsb get secrets tsb-es-elastic-user -o go-template='{{.data.elastic | base64decode}}') \
    --elastic-username elastic \
    --ldap-bind-dn cn=admin,dc=tetrate,dc=io \
    --ldap-bind-password admin \
    --postgres-password $(kubectl -n tsb get secrets tsb-pguser-tsb -o go-template='{{.data.password | base64decode}}') \
    --postgres-username $(kubectl -n tsb get secrets tsb-pguser-tsb -o go-template='{{.data.user | base64decode}}') \
    --tsb-admin-password "$TSB_ADMIN_PASS" \
    --allow-defaults \
    >/tmp/mp-secrets-"$ORG".yaml
    
    if [ $JWT = "true" ]; then
        kubectl delete secret -n "$TSB_NS" mpc-certs 2>/dev/null
    fi
    createPrivateJWTSigner
    kubectl apply -f /tmp/mp-secrets-"$ORG".yaml 2>/dev/null
    
    kubectl delete secret -n "$TSB_NS" tsb-certs 2>/dev/null
    echo "Generating TSB FrontEnvoy Self-Signed Certificates"
    generateSelfSignedTSBCertsForOCP $OCP_DOMAIN
    echo "Creating tsb-cert secret"
    applySeflSignedTSBCertificates
    kubectl get secret -n "$TSB_NS" tsb-certs 2>/dev/null
    check=$?
    counter=20
    while [ $check -ne 0 ] && [ $counter -gt 0 ]; do
        kubectl get secret -n "$TSB_NS" tsb-certs 2>/dev/null
        check=$?
        if [ $check -ne 0 ]; then
            counter=$((counter - 1))
            if [ $counter -eq 0 ]; then
                echo "the tsb-certs secret is not ready"
                exit 1
            fi
            echo "waiting for tsb-cert" $counter
            sleep 10
        fi
    done
else
    echo "MP deployments already exists"
fi
if [ $JWT = "true" ]; then
    cat "$ROOT"/templates/mp-jwt-support.yaml >> /tmp/mgmntplane-cr.yaml
fi
sleep 120
kubectl apply -f /tmp/mgmntplane-cr.yaml
sleep 60
kubectl rollout restart deployment -n cert-manager >/dev/null 2>/dev/null

kubectl rollout status -n "$TSB_NS" deployment/central 2>/dev/null
check=$?
counter=30
while [ $check -ne 0 ] && [ $counter -gt 0 ]; do
    kubectl rollout status -n "$TSB_NS" deployment/central 2>/dev/null
    check=$?
    if [ $check -ne 0 ]; then
        counter=$((counter - 1))
        echo "waiting for Central" $counter
        sleep 10
    fi
done

if ! kubectl wait -n "$TSB_NS" --for=condition=Available --timeout=10m deployment/central 2>/dev/null; then
    echo "TSB deployment failed!"
    exit 1
else
    echo "TSB deployment succeeded"
fi

kubectl rollout restart deployment -n cert-manager >/dev/null 2>/dev/null
kubectl delete job -n "$TSB_NS" teamsync-bootstrap 2>/dev/null
kubectl create job -n "$TSB_NS" teamsync-bootstrap --from=cronjob/teamsync 2>/dev/null
kubectl wait -n "$TSB_NS" --for=Condition=Completed job -n "$TSB_NS" teamsync-bootstrap 2>/dev/null

echo "Waiting for TSB IP/hostname..."
TCCIP=$(getTCCIP)
while [[ -z ${TCCIP} ]]; do
    TCCIP=$(getTCCIP)
    sleep 5
done

if [[ -z "$TCCIP" ]]; then
    echo "Unable to obtain TSB IP"
    exit 1
else
    echo "TSB Front Envoy Address " "$TCCIP"
fi
# updateRoute53 "${DEPLOYMENT_NAME}"-tsb."${DNS_DOMAIN}" "$TCCIP" ${DNS_RECORD_TYPE}
sleep 60
tctlCLIConfig $TCCIP

if ! tctl apply -f /tmp/tctl.yaml; then
    echo "tctl constructs are not applied!"
    exit 1
else
    echo "tctl settings are successfully applied"
fi

oc create route -n tsb passthrough --hostname=tsb."$OCP_DOMAIN" --service=envoy --insecure-policy=Redirect --port=https-ingress

# echo ==========================
# echo ***  please point Public DNS *** per following:
# echo FQDN - tsb."$OCP_DOMAIN" 
# echo forwards to $TCCIP 
# echo ==========================
# echo After DNS is forwarding correctly - you can access TSB via below:

echo ==========================
echo TSB UI Access
echo --------------------------
echo
echo https://tsb."$OCP_DOMAIN"
echo
echo Credentials are admin/"$TSB_ADMIN_PASS"
echo
echo ==========================
