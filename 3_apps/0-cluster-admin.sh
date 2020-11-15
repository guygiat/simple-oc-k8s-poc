#!/bin/bash
source ../config/dap.config
source ../config/$PLATFORM.config
source ../config/utils.sh

echo "Creating namespace & RBAC role bindings..."

#login_as $CLUSTER_ADMIN_USERNAME $CLUSTER_ADMIN_PASSWORD

sed -e "s#{{ TEST_APP_NAMESPACE_NAME }}#$TEST_APP_NAMESPACE_NAME#g"   \
     ./manifests/templates/test-app-rbac.template.yml            |
    sed -e "s#{{ TEST_APP_SA }}#$TEST_APP_SA#g" |
    sed -e "s#{{ CONJUR_SERVICEACCOUNT_NAME }}#$CONJUR_SERVICEACCOUNT_NAME#g" |
    sed -e "s#{{ CONJUR_NAMESPACE_NAME }}#$CONJUR_NAMESPACE_NAME#g" \
    > ./manifests/test-app-rbac-$TEST_APP_NAMESPACE_NAME.yml

$CLI apply -f ./manifests/test-app-rbac-$TEST_APP_NAMESPACE_NAME.yml

sed -e "s#{{ TEST_APP_NAMESPACE_NAME }}#$TEST_APP_NAMESPACE_NAME#g"   \
     ./manifests/templates/dap-secrets-injector-rbac.template.yml    |
    sed -e "s#{{ TEST_APP_SA }}#$TEST_APP_SA#g" \
    > ./manifests/dap-secrets-injector-rbac-$TEST_APP_NAMESPACE_NAME.yml

$CLI apply -f ./manifests/dap-secrets-injector-rbac-$TEST_APP_NAMESPACE_NAME.yml -n $TEST_APP_NAMESPACE_NAME

echo "Secrets Injection RBAC manifests applied."
