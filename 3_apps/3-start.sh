#!/bin/bash
set -euo pipefail

source ../config/dap.config
source ../config/utils.sh

main() {
  check_dependencies

  login_as $DEVELOPER_USERNAME
  ./stop

  load_policies
  create_k8s_secrets
  deploy_test_app
  verify_authentication
}

############################
check_dependencies() {
  check_env_var "CONJUR_VERSION"
  check_env_var "CONJUR_NAMESPACE_NAME"
  check_env_var "TEST_APP_NAMESPACE_NAME"
  check_env_var "DOCKER_REGISTRY_URL"
  check_env_var "CONJUR_ACCOUNT"
  check_env_var "CONJUR_ADMIN_PASSWORD"
  check_env_var "AUTHENTICATOR_ID"
}

############################
load_policies() {
  announce "Initializing Conjur authorization policies..."

  sed -e "s#{{ AUTHENTICATOR_ID }}#$AUTHENTICATOR_ID#g" \
    ./policy/templates/project-authn-defs.template.yml |
    sed -e "s#{{ TEST_APP_NAMESPACE_NAME }}#$TEST_APP_NAMESPACE_NAME#g" \
    > ./policy/project-authn-defs.yml

  sed -e "s#{{ AUTHENTICATOR_ID }}#$AUTHENTICATOR_ID#g" \
      ./policy/templates/app-identity-defs.template.yml |
    sed -e "s#{{ TEST_APP_NAMESPACE_NAME }}#$TEST_APP_NAMESPACE_NAME#g" \
    > ./policy/app-identity-defs.yml

  sed -e "s#{{ AUTHENTICATOR_ID }}#$AUTHENTICATOR_ID#g" \
      ./policy/templates/resource-access-grants.template.yml |
    sed -e "s#{{ TEST_APP_NAMESPACE_NAME }}#$TEST_APP_NAMESPACE_NAME#g" \
    > ./policy/resource-access-grants.yml

  POLICY_FILE_LIST="
policy/project-authn-defs.yml
policy/app-identity-defs.yml
policy/resource-access-grants.yml
"
  for i in $POLICY_FILE_LIST; do
    echo "Loading policy file: $i"
    load_policy_REST.sh root "./$i"
  done

  # create initial value for variables
  var_value_add_REST.sh k8s-secrets/db-username the-db-username
  var_value_add_REST.sh k8s-secrets/db-password $(openssl rand -hex 12)

  echo "Conjur policies loaded."
}

############################
deploy_test_app() {
  announce "Deploying test apps for $TEST_APP_NAMESPACE_NAME."
  copy_conjur_config_map
  create_app_config_map

  registry_login
  deploy_sidecar_app
  deploy_init_container_app
  sleep 12  # allow time for containers to initialize
}

###########################
# create copy of conjur config map in the app namespace
copy_conjur_config_map() {
  if [[ $TEST_APP_NAMESPACE_NAME == $CONJUR_NAMESPACE_NAME ]]; then
    return
  fi
  $CLI delete --ignore-not-found cm $CONJUR_CONFIG_MAP -n $TEST_APP_NAMESPACE_NAME
  $CLI get cm $CONJUR_CONFIG_MAP -n $CONJUR_NAMESPACE_NAME -o yaml \
    | sed "s/namespace: $CONJUR_NAMESPACE_NAME/namespace: $TEST_APP_NAMESPACE_NAME/" \
    | $CLI create -f -
}

###########################
# APP_CONFIG_MAP defines values for app authentication
#
create_app_config_map() {
  $CLI delete --ignore-not-found configmap $APP_CONFIG_MAP -n $TEST_APP_NAMESPACE_NAME
  
  # Set authn URL to either Follower service in cluster or external Follower
  if $CONJUR_FOLLOWERS_IN_CLUSTER; then
    conjur_appliance_url=https://conjur-follower.$CONJUR_NAMESPACE_NAME.svc.cluster.local/api
  else
    conjur_appliance_url=https://$CONJUR_MASTER_HOST_NAME:$CONJUR_FOLLOWER_PORT
  fi

  conjur_authenticator_url=$conjur_appliance_url/authn-k8s/$AUTHENTICATOR_ID
  conjur_authn_login_prefix=host/conjur/authn-k8s/$AUTHENTICATOR_ID/apps/$TEST_APP_NAMESPACE_NAME/service_account

  $CLI create configmap $APP_CONFIG_MAP \
        -n $TEST_APP_NAMESPACE_NAME \
        --from-literal=conjur-authn-url="$conjur_authenticator_url" \
        --from-literal=conjur-authn-login-init="$conjur_authn_login_prefix/test-app-summon-init" \
        --from-literal=conjur-authn-login-sidecar="$conjur_authn_login_prefix/test-app-summon-sidecar"
}

###########################
deploy_sidecar_app() {
  $CLI delete -n $TEST_APP_NAMESPACE_NAME --ignore-not-found \
    deployment/test-app-summon-sidecar \
    service/test-app-summon-sidecar \
    serviceaccount/test-app-summon-sidecar \
    serviceaccount/oc-test-app-summon-sidecar

  sleep 5

  sed -e "s#{{ TEST_APP_IMAGE }}#$TEST_APP_REG_IMAGE#g" \
      ./manifests/templates/test-app-summon-sidecar.template.yml |
    sed -e "s#{{ AUTHENTICATOR_CLIENT_IMAGE }}#$AUTHENTICATOR_CLIENT_REG_IMAGE#g" |
    sed -e "s#{{ IMAGE_PULL_POLICY }}#$IMAGE_PULL_POLICY#g" |
    sed -e "s#{{ CONJUR_MASTER_HOST_NAME }}#$CONJUR_MASTER_HOST_NAME#g" |
    sed -e "s#{{ CONJUR_MASTER_HOST_IP }}#$CONJUR_MASTER_HOST_IP#g" |
    sed -e "s#{{ TEST_APP_NAMESPACE_NAME }}#$TEST_APP_NAMESPACE_NAME#g" |
    sed -e "s#{{ CONJUR_CONFIG_MAP }}#$CONJUR_CONFIG_MAP#g" |
    sed -e "s#{{ APP_CONFIG_MAP }}#$APP_CONFIG_MAP#g" \
    > ./manifests/test-app-summon-sidecar-$TEST_APP_NAMESPACE_NAME.yml

  $CLI create -f ./manifests/test-app-summon-sidecar-$TEST_APP_NAMESPACE_NAME.yml -n $TEST_APP_NAMESPACE_NAME

  echo "Test app/sidecar deployed."
}

###########################
deploy_init_container_app() {
  $CLI delete -n $TEST_APP_NAMESPACE_NAME --ignore-not-found \
    deployment/test-app-summon-init \
    service/test-app-summon-init \
    serviceaccount/test-app-summon-init \
    serviceaccount/oc-test-app-summon-init

  sleep 5

  sed -e "s#{{ TEST_APP_IMAGE }}#$TEST_APP_REG_IMAGE#g" \
      ./manifests/templates/test-app-summon-init.template.yml |
    sed -e "s#{{ AUTHENTICATOR_CLIENT_IMAGE }}#$AUTHENTICATOR_CLIENT_REG_IMAGE#g" |
    sed -e "s#{{ IMAGE_PULL_POLICY }}#$IMAGE_PULL_POLICY#g" |
    sed -e "s#{{ CONJUR_MASTER_HOST_NAME }}#$CONJUR_MASTER_HOST_NAME#g" |
    sed -e "s#{{ CONJUR_MASTER_HOST_IP }}#$CONJUR_MASTER_HOST_IP#g" |
    sed -e "s#{{ TEST_APP_NAMESPACE_NAME }}#$TEST_APP_NAMESPACE_NAME#g" |
    sed -e "s#{{ CONJUR_CONFIG_MAP }}#$CONJUR_CONFIG_MAP#g" |
    sed -e "s#{{ APP_CONFIG_MAP }}#$APP_CONFIG_MAP#g" \
    > ./manifests/test-app-summon-init-$TEST_APP_NAMESPACE_NAME.yml

  $CLI create -f ./manifests/test-app-summon-init-$TEST_APP_NAMESPACE_NAME.yml -n $TEST_APP_NAMESPACE_NAME

  echo "Test app/init-container deployed."
}

###########################
create_k8s_secrets() {
  $CLI delete secret test-app-secret -n $TEST_APP_NAMESPACE_NAME --ignore-not-found 
  $CLI create secret generic test-app-secret \
	--from-literal=secret-key=Can-You-Read-This-Secret? -n $TEST_APP_NAMESPACE_NAME
}

###########################
verify_authentication() {
  clear
  announce "Retrieving secrets with access token."

  sidecar_api_pod=$($CLI get pods -n $TEST_APP_NAMESPACE_NAME --no-headers -l app=test-app-summon-sidecar | awk '{ print $1 }')
  if [[ "$sidecar_api_pod" != "" ]]; then
    echo "Sidecar + REST API: $($CLI exec -n $TEST_APP_NAMESPACE_NAME -c test-app $sidecar_api_pod -- /webapp.sh)"
    echo "Sidecar + Summon:"
    echo "$($CLI exec -n $TEST_APP_NAMESPACE_NAME -c test-app $sidecar_api_pod -- summon /webapp_summon.sh)"
  fi

  init_api_pod=$($CLI get pods -n $TEST_APP_NAMESPACE_NAME --no-headers -l app=test-app-summon-init | awk '{ print $1 }')
  if [[ "$init_api_pod" != "" ]]; then
    echo
    echo "Init Container + REST API: $($CLI exec -n $TEST_APP_NAMESPACE_NAME -c test-app $init_api_pod -- /webapp.sh)"
    echo "Init Container + Summon:"
    echo "$($CLI exec -n $TEST_APP_NAMESPACE_NAME -c test-app $init_api_pod -- summon /webapp_summon.sh)"
  fi
}

main "$@"