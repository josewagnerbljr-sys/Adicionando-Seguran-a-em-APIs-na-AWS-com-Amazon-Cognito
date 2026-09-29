#!/usr/bin/env bash
# Automação do desafio com AWS CLI v2.
#   bash scripts/aws.sh deploy    # cria tudo (DynamoDB, IAM, Lambda, Cognito, API Gateway)
#   bash scripts/aws.sh test      # testa 401 sem token e 200 com token do Cognito
#   bash scripts/aws.sh destroy   # remove tudo para não gerar custo
set -euo pipefail
export MSYS_NO_PATHCONV=1   # evita conversão de caminhos no Git Bash
export AWS_PAGER=""

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
STATE_FILE="$BUILD_DIR/state.env"
cd "$ROOT_DIR"

REGION="${AWS_REGION:-sa-east-1}"
TABLE="Itens"
FUNC="put_item_function"
ROLE="put_item_function_role"
API_NAME="dio_live_api"
POOL_NAME="TestPool"
CLIENT_NAME="TestClient"
AUTHORIZER_NAME="CognitoAuth"
STAGE="dev"
DOMAIN_PREFIX="${DOMAIN_PREFIX:-diolive-$RANDOM$RANDOM}"   # precisa ser único na região

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "Comando '$1' não encontrado."; exit 1; }; }

make_zip() {
  mkdir -p "$BUILD_DIR"
  rm -f "$BUILD_DIR/function.zip"
  if command -v zip >/dev/null 2>&1; then
    (cd src && zip -q -j "../build/function.zip" put_item_function.js)
  else
    # Git Bash normalmente não traz 'zip': usa o PowerShell do Windows
    (cd src && powershell.exe -NoProfile -Command \
      "Compress-Archive -Path 'put_item_function.js' -DestinationPath '../build/function.zip' -Force")
  fi
}

deploy() {
  need aws
  mkdir -p "$BUILD_DIR"
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  log "Conta AWS: $ACCOUNT_ID | Região: $REGION"

  log "1/8 Criando tabela DynamoDB '$TABLE' (chave de partição: id)"
  aws dynamodb create-table --region "$REGION" --table-name "$TABLE" \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --region "$REGION" --table-name "$TABLE"

  log "2/8 Criando role IAM e política inline (dynamodb:PutItem)"
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document file://iam/lambda_trust_policy.json >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  sed -e "s/__REGION__/$REGION/g" -e "s/__ACCOUNT_ID__/$ACCOUNT_ID/g" -e "s/__TABLE__/$TABLE/g" \
    iam/lambda_dynamodb_putItem_policy.json > build/policy.json
  aws iam put-role-policy --role-name "$ROLE" \
    --policy-name lambda_dynamodb_putItem_policy --policy-document file://build/policy.json
  ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE"
  sleep 12   # propagação do IAM

  log "3/8 Publicando função Lambda '$FUNC'"
  make_zip
  for i in 1 2 3 4 5; do
    if aws lambda create-function --region "$REGION" --function-name "$FUNC" \
        --runtime nodejs22.x --handler put_item_function.handler \
        --role "$ROLE_ARN" --zip-file fileb://build/function.zip \
        --environment "Variables={TABLE_NAME=$TABLE}" --timeout 10 >/dev/null 2>&1; then
      break
    fi
    echo "   role ainda propagando... tentativa $i/5"; sleep 8
    [ "$i" = 5 ] && { echo "Falha ao criar a Lambda."; exit 1; }
  done
  aws lambda wait function-active-v2 --region "$REGION" --function-name "$FUNC" 2>/dev/null || sleep 5
  LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$FUNC"

  log "4/8 Criando User Pool, App Client e domínio do Cognito"
  POOL_ID="$(aws cognito-idp create-user-pool --region "$REGION" --pool-name "$POOL_NAME" \
    --username-attributes email --auto-verified-attributes email --mfa-configuration OFF \
    --verification-message-template DefaultEmailOption=CONFIRM_WITH_LINK \
    --query UserPool.Id --output text)"
  CLIENT_ID="$(aws cognito-idp create-user-pool-client --region "$REGION" \
    --user-pool-id "$POOL_ID" --client-name "$CLIENT_NAME" --generate-no-secret \
    --supported-identity-providers COGNITO \
    --allowed-o-auth-flows code implicit --allowed-o-auth-flows-user-pool-client \
    --allowed-o-auth-scopes email openid \
    --callback-urls https://example.com/logout https://oauth.pstmn.io/v1/callback \
    --logout-urls https://example.com/logout \
    --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --query UserPoolClient.ClientId --output text)"
  aws cognito-idp create-user-pool-domain --region "$REGION" \
    --user-pool-id "$POOL_ID" --domain "$DOMAIN_PREFIX" >/dev/null
  POOL_ARN="arn:aws:cognito-idp:$REGION:$ACCOUNT_ID:userpool/$POOL_ID"

  log "5/8 Criando API REST '$API_NAME' e recurso /Itens"
  API_ID="$(aws apigateway create-rest-api --region "$REGION" --name "$API_NAME" \
    --endpoint-configuration types=REGIONAL --query id --output text)"
  ROOT_RES="$(aws apigateway get-resources --region "$REGION" --rest-api-id "$API_ID" \
    --query 'items[?path==`/`].id' --output text)"
  RES_ID="$(aws apigateway create-resource --region "$REGION" --rest-api-id "$API_ID" \
    --parent-id "$ROOT_RES" --path-part Itens --query id --output text)"

  log "6/8 Criando autorizador Cognito '$AUTHORIZER_NAME'"
  AUTH_ID="$(aws apigateway create-authorizer --region "$REGION" --rest-api-id "$API_ID" \
    --name "$AUTHORIZER_NAME" --type COGNITO_USER_POOLS --provider-arns "$POOL_ARN" \
    --identity-source method.request.header.Authorization --query id --output text)"

  log "7/8 Método POST protegido + integração Lambda Proxy"
  aws apigateway put-method --region "$REGION" --rest-api-id "$API_ID" --resource-id "$RES_ID" \
    --http-method POST --authorization-type COGNITO_USER_POOLS --authorizer-id "$AUTH_ID" >/dev/null
  aws apigateway put-integration --region "$REGION" --rest-api-id "$API_ID" --resource-id "$RES_ID" \
    --http-method POST --type AWS_PROXY --integration-http-method POST \
    --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations" >/dev/null
  aws lambda add-permission --region "$REGION" --function-name "$FUNC" \
    --statement-id apigw-invoke-post-itens --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/POST/Itens" >/dev/null

  log "8/8 Implantando no estágio '$STAGE'"
  aws apigateway create-deployment --region "$REGION" --rest-api-id "$API_ID" \
    --stage-name "$STAGE" >/dev/null

  API_URL="https://$API_ID.execute-api.$REGION.amazonaws.com/$STAGE/Itens"
  cat > "$STATE_FILE" <<STATE
REGION=$REGION
ACCOUNT_ID=$ACCOUNT_ID
API_ID=$API_ID
API_URL=$API_URL
POOL_ID=$POOL_ID
CLIENT_ID=$CLIENT_ID
DOMAIN_PREFIX=$DOMAIN_PREFIX
STATE

  cat <<INFO

Deploy concluído.
  Endpoint (POST):  $API_URL
  User Pool ID:     $POOL_ID
  Client ID:        $CLIENT_ID
  Login (Hosted UI): https://$DOMAIN_PREFIX.auth.$REGION.amazoncognito.com/login
                     ?client_id=$CLIENT_ID&response_type=token&scope=email+openid&redirect_uri=https://example.com/logout

Próximo passo: bash scripts/aws.sh test
INFO
}

test_api() {
  need curl
  [ -f "$STATE_FILE" ] || { echo "Rode 'deploy' antes."; exit 1; }
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  local email="${TEST_EMAIL:-teste.dio@example.com}"
  local pass="${TEST_PASSWORD:-Dio@Cognito2025!}"
  local body='{"id":"003","price":600}'

  log "Teste 1: SEM token (esperado HTTP 401)"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL" \
    -H 'Content-Type: application/json' -d "$body")"
  echo "HTTP $code"

  log "Criando usuário de teste no Cognito ($email)"
  aws cognito-idp admin-create-user --region "$REGION" --user-pool-id "$POOL_ID" \
    --username "$email" --message-action SUPPRESS \
    --user-attributes Name=email,Value="$email" Name=email_verified,Value=true >/dev/null 2>&1 || true
  aws cognito-idp admin-set-user-password --region "$REGION" --user-pool-id "$POOL_ID" \
    --username "$email" --password "$pass" --permanent

  log "Obtendo ID Token"
  TOKEN="$(aws cognito-idp initiate-auth --region "$REGION" --client-id "$CLIENT_ID" \
    --auth-flow USER_PASSWORD_AUTH --auth-parameters USERNAME="$email",PASSWORD="$pass" \
    --query AuthenticationResult.IdToken --output text)"

  log "Teste 2: COM token (esperado HTTP 200)"
  curl -s -w '\nHTTP %{http_code}\n' -X POST "$API_URL" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -d "$body"

  log "Conferindo o item no DynamoDB"
  aws dynamodb get-item --region "$REGION" --table-name "$TABLE" --key '{"id":{"S":"003"}}'
}

destroy() {
  [ -f "$STATE_FILE" ] || { echo "Nada para remover (state.env não encontrado)."; exit 0; }
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  log "Removendo recursos"
  aws apigateway delete-rest-api --region "$REGION" --rest-api-id "$API_ID" || true
  aws cognito-idp delete-user-pool-domain --region "$REGION" --user-pool-id "$POOL_ID" --domain "$DOMAIN_PREFIX" || true
  aws cognito-idp delete-user-pool --region "$REGION" --user-pool-id "$POOL_ID" || true
  aws lambda delete-function --region "$REGION" --function-name "$FUNC" || true
  aws iam delete-role-policy --role-name "$ROLE" --policy-name lambda_dynamodb_putItem_policy || true
  aws iam detach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole || true
  aws iam delete-role --role-name "$ROLE" || true
  aws dynamodb delete-table --region "$REGION" --table-name "$TABLE" >/dev/null || true
  rm -f "$STATE_FILE"
  echo "Tudo removido."
}

case "${1:-}" in
  deploy)  deploy ;;
  test)    test_api ;;
  destroy) destroy ;;
  *) echo "Uso: bash scripts/aws.sh {deploy|test|destroy}"; exit 1 ;;
esac
