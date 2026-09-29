"use strict";

/**
 * put_item_function
 * Insere um item na tabela DynamoDB "Itens" (chave de partição: id).
 *
 * Integração: API Gateway (REST) + Lambda Proxy, protegida por autorizador
 * Amazon Cognito User Pools. As claims do token validado chegam em
 * event.requestContext.authorizer.claims.
 *
 * Body esperado (JSON):  { "id": "003", "price": 600 }
 */
const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, PutCommand } = require("@aws-sdk/lib-dynamodb");

const TABLE_NAME = process.env.TABLE_NAME || "Itens";
const client = new DynamoDBClient({});
const ddb = DynamoDBDocumentClient.from(client);

const json = (statusCode, payload) => ({
  statusCode,
  headers: {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
  },
  body: JSON.stringify(payload),
});

const parseBody = (event) => {
  if (!event.body) return null;
  const raw = event.isBase64Encoded
    ? Buffer.from(event.body, "base64").toString("utf8")
    : event.body;
  return JSON.parse(raw);
};

exports.handler = async (event) => {
  let body;
  try {
    body = parseBody(event);
  } catch (err) {
    return json(400, { message: "JSON inválido no corpo da requisição." });
  }

  if (!body) {
    return json(400, { message: "Corpo da requisição ausente." });
  }

  const { id, price } = body;

  if ((typeof id !== "string" && typeof id !== "number") || String(id).trim() === "") {
    return json(400, { message: "Campo 'id' é obrigatório (texto não vazio)." });
  }
  if (typeof price !== "number" || !Number.isFinite(price) || price < 0) {
    return json(400, { message: "Campo 'price' deve ser um número maior ou igual a zero." });
  }

  const claims = event.requestContext?.authorizer?.claims || {};

  const item = {
    id: String(id),
    price,
    createdAt: new Date().toISOString(),
    createdBy: claims.email || claims.sub || "desconhecido",
  };

  try {
    await ddb.send(new PutCommand({ TableName: TABLE_NAME, Item: item }));
    return json(200, { message: "Item inserido com sucesso.", item });
  } catch (err) {
    console.error("Erro ao gravar no DynamoDB:", err);
    return json(500, { message: "Erro interno ao gravar o item." });
  }
};
