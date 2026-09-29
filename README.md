# Adicionando Segurança em APIs na AWS com Amazon Cognito

Projeto do desafio DIO em que uma API REST é protegida por **autenticação e autorização com Amazon Cognito**. O API Gateway só encaminha a requisição à Lambda se ela trouxer um token JWT válido emitido pelo User Pool.

> Baseado na implementação de referência [cassianobrexbit/dio-live-cognito](https://github.com/cassianobrexbit/dio-live-cognito) (DIO Live Coding de 17/11/2021), evoluído com validação de entrada, menor privilégio no IAM, coleção Postman e automação via AWS CLI.

## Arquitetura

```
 Cliente (Postman / App)
        |
        | 1) login (Hosted UI / OAuth 2.0)  --->  Amazon Cognito User Pool
        |                                         (emite ID Token / Access Token JWT)
        | 2) POST /dev/Itens  +  Authorization: Bearer <token>
        v
 Amazon API Gateway (REST) --- Cognito Authorizer (valida o JWT)
        |  token válido            token ausente/inválido -> 401
        v
 AWS Lambda (put_item_function, Node.js 22)
        |
        v
 Amazon DynamoDB (tabela Itens, chave de partição: id)
```

## Serviços utilizados

| Serviço | Papel |
|---|---|
| Amazon Cognito | Cadastro, login e emissão de tokens (User Pool + App Client + domínio) |
| Amazon API Gateway | API REST `dio_live_api`, recurso `/Itens`, autorizador `CognitoAuth` |
| AWS Lambda | Função `put_item_function` (regra de negócio) |
| Amazon DynamoDB | Tabela `Itens` |
| AWS IAM | Role da Lambda com permissão mínima (`dynamodb:PutItem`) |
| Postman | Obtenção do token e testes |

## Estrutura do repositório

```
.
├── README.md                                  # este arquivo (único)
├── .gitignore
├── src/
│   └── put_item_function.js                   # código da Lambda
├── iam/
│   ├── lambda_trust_policy.json               # quem pode assumir a role
│   └── lambda_dynamodb_putItem_policy.json    # política inline (template)
├── postman/
│   └── dio_live_api.postman_collection.json   # coleção de testes
└── scripts/
    └── aws.sh                                 # deploy | test | destroy via AWS CLI
```

## Opção 1: Automação (AWS CLI)

Pré-requisitos: AWS CLI v2 configurada (`aws configure`) com permissões para IAM, Lambda, DynamoDB, Cognito e API Gateway.

```bash
bash scripts/aws.sh deploy     # cria toda a infraestrutura em sa-east-1
bash scripts/aws.sh test       # 401 sem token / 200 com token / confere no DynamoDB
bash scripts/aws.sh destroy    # apaga tudo (evita custos)
```

Para outra região: `AWS_REGION=us-east-1 bash scripts/aws.sh deploy`.

## Opção 2: Passo a passo no console (como na live)

### 1. Criar a API REST no API Gateway
1. API Gateway → **Criar API** → **API REST** → *Build*.
2. Nome `dio_live_api`, tipo de endpoint **Regional**.
3. **Criar recurso** com o nome `Itens` (path `/Itens`).

### 2. Criar a tabela no DynamoDB
1. DynamoDB → **Criar tabela**.
2. Nome `Itens`, chave de partição `id` (String).

### 3. Criar a função Lambda
1. Lambda → **Criar função** → nome `put_item_function` (runtime Node.js 22.x).
2. Cole o conteúdo de `src/put_item_function.js` e clique em **Deploy**.
3. Em *Configuração → Variáveis de ambiente*, crie `TABLE_NAME = Itens` (opcional, o padrão já é `Itens`).
4. Em *Configuração → Permissões*, abra a role no IAM → **Adicionar permissões → Criar política inline**:
   - Serviço **DynamoDB**, ação **PutItem**, recurso = ARN da tabela `Itens`.
   - Nome da política: `lambda_dynamodb_putItem_policy` (modelo em `iam/`).

### 4. Integrar API Gateway e Lambda
1. Selecione o recurso `/Itens` → **Criar método** → `POST`.
2. Tipo de integração **Função Lambda**, marque **Usar integração de proxy Lambda** e escolha `put_item_function`.
3. **Implantar API** → novo estágio `dev`.

### 5. Testar sem segurança (ainda aberto)
No Postman: `POST` para `https://<api-id>.execute-api.<regiao>.amazonaws.com/dev/Itens`, *Body → raw → JSON*:

```json
{
  "id": "003",
  "price": 600
}
```

Deve retornar **200** e o item aparece no DynamoDB.

### 6. Criar o User Pool no Cognito
1. Cognito → **Criar grupo de usuários** `TestPool`.
2. Login por **e-mail**; MFA **desligado**; verificação de e-mail por **link**.
3. App client `TestClient` (sem client secret).
4. Configurações do app client (Hosted UI / Managed Login):
   - Provedor de identidade: **Cognito user pool**.
   - URL de retorno permitida: `https://example.com/logout` (e `https://oauth.pstmn.io/v1/callback` para o Postman).
   - Fluxos OAuth: **Authorization code grant** e **Implicit grant**.
   - Escopos: `openid` e `email`.
5. Configure o **domínio** com prefixo `diolive` (precisa ser único; adicione um sufixo se já existir).

> O console do Cognito foi redesenhado desde a live (por exemplo, "Managed login" no lugar do Hosted UI antigo). Os nomes mudam, mas as configurações são as mesmas.

### 7. Criar o autorizador Cognito no API Gateway
1. API Gateway → sua API → **Autorizadores** → **Criar**.
2. Nome `CognitoAuth`, tipo **Cognito**, User Pool `TestPool`, origem do token `Authorization`.
3. Recurso `/Itens` → método `POST` → **Solicitação de método** → *Autorização* = `CognitoAuth`.
4. **Implante a API novamente** no estágio `dev`. Sem novo deploy a proteção não entra em vigor.

### 8. Testar com segurança no Postman
1. Crie um usuário: abra o login do Hosted UI, use *Sign up* e confirme o e-mail.
2. Na request: aba **Authorization** → tipo **OAuth 2.0** e configure:
   - Callback URL: `https://example.com/logout` (ou a do Postman).
   - Auth URL: `https://<prefixo>.auth.<regiao>.amazoncognito.com/login`
   - Access Token URL: `https://<prefixo>.auth.<regiao>.amazoncognito.com/oauth2/token`
   - Client ID: o do App client. Scope: `openid email`.
   - *Client Authentication*: enviar credenciais no corpo.
3. **Get New Access Token**, faça login e use o token.
4. Na request `POST /Itens`: **Authorization → Bearer Token** → cole o token e envie.

Resultado esperado: sem token **401 Unauthorized**; com token válido **200 OK**.

## Testes com a coleção Postman
Importe `postman/dio_live_api.postman_collection.json`, preencha as variáveis `baseUrl` (inclui o estágio, ex.: `.../dev`) e `idToken`, e execute as duas requests.

## Erros comuns

| Sintoma | Causa provável | Solução |
|---|---|---|
| `401 Unauthorized` com token | Token do tipo errado | Sem escopos configurados no método, o autorizador espera o **ID Token**. Use o ID Token (Postman: *Use Token Type → ID Token*). |
| `403 Missing Authentication Token` | URL errada | Verifique estágio e recurso: `/dev/Itens` e método `POST`. |
| `403 Forbidden` após proteger | API não reimplantada | **Implantar API** novamente. |
| `502 Bad Gateway` | Resposta fora do formato proxy ou erro na Lambda | Confira o CloudWatch Logs; a resposta precisa ter `statusCode` e `body` (string). |
| `500` da Lambda | Role sem permissão ou tabela com outro nome | Revise a política inline e a variável `TABLE_NAME`. |
| Domínio Cognito já existe | Prefixo é global na região | Use outro prefixo (`DOMAIN_PREFIX=meu-prefixo bash scripts/aws.sh deploy`). |
| `redirect_mismatch` | URL de retorno não cadastrada | Cadastre exatamente a mesma URL usada no Postman. |

## Boas práticas aplicadas
- **Menor privilégio**: a Lambda só pode executar `PutItem` na tabela `Itens`.
- **Validação de entrada** (JSON, `id`, `price`) com respostas 400 claras.
- **Identidade auditável**: a Lambda grava `createdBy` a partir das claims do token validado.
- **Infraestrutura reproduzível** e removível com um comando.
- **Sem segredos no repositório** (`.gitignore` cobre `build/` e `.env`).

## Próximos passos possíveis
Grupos do Cognito para autorização por perfil (admin/usuário), escopos personalizados com Resource Server, CORS configurado por origem, WAF e throttling no estágio, e IaC com AWS SAM ou Terraform.

## Referências
- [Amazon Cognito: Guia do desenvolvedor](https://docs.aws.amazon.com/cognito/latest/developerguide/)
- [Controlar o acesso a uma API REST com grupos de usuários do Cognito](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)
- [Repositório de referência da live](https://github.com/cassianobrexbit/dio-live-cognito)

## Autor
**José Wagner Blanco Júnior**: [github.com/josewagnerbljr-sys](https://github.com/josewagnerbljr-sys)

## Status
Código e automação publicados. A validação na AWS (deploy, prints do 401/200 no Postman e do item no DynamoDB) será adicionada assim que a verificação da conta for concluída.
