import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import emailStart from "./api/auth/email/start.js";
import otpStart from "./api/auth/otp/start.js";
import otpVerify from "./api/auth/otp/verify.js";
import sessionStatus from "./api/auth/session/status.js";
import sessionComplete from "./api/auth/session/complete.js";

export const LOCAL_BIND_ADDRESS = "127.0.0.1";
export const DEFAULT_LOCAL_AUTH_API_PORT = 3000;
export const MAX_BODY_BYTES = 64 * 1024;

const ROUTES = Object.freeze({
  "/api/auth/email/start": emailStart,
  "/api/auth/otp/start": otpStart,
  "/api/auth/otp/verify": otpVerify,
  "/api/auth/session/status": sessionStatus,
  "/api/auth/session/complete": sessionComplete,
});

export class LocalRequestError extends Error {
  constructor(statusCode, publicMessage) {
    super(publicMessage);
    this.statusCode = statusCode;
    this.publicMessage = publicMessage;
  }
}

export function routeHandlerFor(pathname) {
  return Object.hasOwn(ROUTES, pathname) ? ROUTES[pathname] : undefined;
}

export async function parseJsonBody(request, maxBytes = MAX_BODY_BYTES) {
  const contentType = request.headers?.["content-type"];
  if (
    typeof contentType !== "string" ||
    contentType.split(";", 1)[0].trim().toLowerCase() !== "application/json"
  ) {
    throw new LocalRequestError(415, "Send a JSON request body.");
  }

  const contentLength = Number(request.headers?.["content-length"]);
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    request.resume?.();
    throw new LocalRequestError(413, "The request body is too large.");
  }

  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += bytes.byteLength;
    if (size > maxBytes) {
      request.resume?.();
      throw new LocalRequestError(413, "The request body is too large.");
    }
    chunks.push(bytes);
  }

  if (size === 0) return {};

  let body;
  try {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(
      Buffer.concat(chunks, size),
    );
    body = JSON.parse(text);
  } catch {
    throw new LocalRequestError(400, "Send a valid JSON object.");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new LocalRequestError(400, "Send a valid JSON object.");
  }
  return body;
}

function setLocalResponseHeaders(response) {
  response.setHeader("Access-Control-Allow-Origin", "*");
  response.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  response.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  response.setHeader("Access-Control-Expose-Headers", "Retry-After");
  response.setHeader("Cache-Control", "no-store");
}

function makeHandlerResponse(response) {
  const adapter = {
    status(statusCode) {
      if (!response.headersSent) response.statusCode = statusCode;
      return adapter;
    },
    setHeader(name, value) {
      if (!response.headersSent) response.setHeader(name, value);
      return adapter;
    },
    json(value) {
      if (response.writableEnded) return adapter;
      if (!response.headersSent) {
        response.setHeader("Content-Type", "application/json; charset=utf-8");
      }
      response.end(JSON.stringify(value));
      return adapter;
    },
    end(value) {
      if (!response.writableEnded) response.end(value);
      return adapter;
    },
  };
  return adapter;
}

function sendError(response, statusCode, message) {
  response.status(statusCode).json({ error: message });
}

async function handleRequest(request, response) {
  setLocalResponseHeaders(response);

  let pathname;
  try {
    pathname = new URL(request.url || "/", `http://${LOCAL_BIND_ADDRESS}`).pathname;
  } catch {
    return sendError(makeHandlerResponse(response), 400, "Invalid request path.");
  }

  const handler = routeHandlerFor(pathname);
  const handlerResponse = makeHandlerResponse(response);
  if (!handler) return sendError(handlerResponse, 404, "Endpoint not found.");
  if (request.method !== "POST" && request.method !== "OPTIONS") {
    handlerResponse.setHeader("Allow", "POST, OPTIONS");
    return sendError(handlerResponse, 405, "Use POST for this endpoint.");
  }

  let body;
  if (request.method === "POST") {
    try {
      body = await parseJsonBody(request);
    } catch (error) {
      if (error instanceof LocalRequestError) {
        return sendError(handlerResponse, error.statusCode, error.publicMessage);
      }
      return sendError(handlerResponse, 400, "Send a valid JSON object.");
    }
  }

  try {
    await handler(
      { method: request.method, headers: request.headers, body },
      handlerResponse,
    );
    if (!response.writableEnded) {
      sendError(handlerResponse, 500, "The auth service could not complete the request.");
    }
  } catch {
    if (!response.writableEnded) {
      sendError(handlerResponse, 500, "The auth service could not complete the request.");
    }
  }
}

export function createLocalAuthServer() {
  return createServer((request, response) => {
    void handleRequest(request, response);
  });
}

function runLocalServer() {
  const rawPort =
    process.env.LOCAL_AUTH_API_PORT || String(DEFAULT_LOCAL_AUTH_API_PORT);
  const port = Number(rawPort);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    console.error("[local-auth-api] LOCAL_AUTH_API_PORT must be a valid port number.");
    process.exitCode = 1;
    return;
  }

  const server = createLocalAuthServer();
  server.on("error", () => {
    console.error("[local-auth-api] Could not bind the loopback listener.");
    process.exitCode = 1;
  });
  server.listen(port, LOCAL_BIND_ADDRESS, () => {
    console.log(`Local auth API listening at http://${LOCAL_BIND_ADDRESS}:${port}`);
  });
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href &&
  fileURLToPath(import.meta.url) === resolve(process.argv[1])
) {
  runLocalServer();
}
