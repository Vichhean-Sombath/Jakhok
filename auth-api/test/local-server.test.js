import assert from "node:assert/strict";
import test from "node:test";

import {
  LOCAL_BIND_ADDRESS,
  DEFAULT_LOCAL_AUTH_API_PORT,
  LocalRequestError,
  MAX_BODY_BYTES,
  parseJsonBody,
  routeHandlerFor,
} from "../local-server.js";

function requestWith(chunks, headers = { "content-type": "application/json" }) {
  return {
    headers,
    resume() {},
    async *[Symbol.asyncIterator]() {
      yield* chunks;
    },
  };
}

test("local server binds loopback and exposes only explicit API routes", () => {
  assert.equal(LOCAL_BIND_ADDRESS, "127.0.0.1");
  assert.equal(DEFAULT_LOCAL_AUTH_API_PORT, 3000);
  for (const pathname of [
    "/api/auth/email/start",
    "/api/auth/otp/start",
    "/api/auth/otp/verify",
    "/api/auth/session/status",
    "/api/auth/session/complete",
  ]) {
    assert.equal(typeof routeHandlerFor(pathname), "function");
  }
  assert.equal(routeHandlerFor("/api/auth/session/status/"), undefined);
  assert.equal(routeHandlerFor("/api/auth/../../local-server.js"), undefined);
  assert.equal(routeHandlerFor("/api/auth/unknown"), undefined);
});

test("local server parses bounded JSON objects", async () => {
  const result = await parseJsonBody(
    requestWith([Buffer.from('{"idToken":"abc"}')]),
  );
  assert.deepEqual(result, { idToken: "abc" });

  await assert.rejects(
    parseJsonBody(requestWith([Buffer.from("[1,2]")])),
    (error) => error instanceof LocalRequestError && error.statusCode === 400,
  );
  await assert.rejects(
    parseJsonBody(requestWith([Buffer.from("not json")])),
    (error) => error instanceof LocalRequestError && error.statusCode === 400,
  );
  await assert.rejects(
    parseJsonBody(requestWith([Buffer.from("{}")], { "content-type": "text/plain" })),
    (error) => error instanceof LocalRequestError && error.statusCode === 415,
  );
});

test("local server rejects declared and streamed bodies over the limit", async () => {
  await assert.rejects(
    parseJsonBody(
      requestWith([], {
        "content-type": "application/json",
        "content-length": String(MAX_BODY_BYTES + 1),
      }),
    ),
    (error) => error instanceof LocalRequestError && error.statusCode === 413,
  );
  await assert.rejects(
    parseJsonBody(
      requestWith([Buffer.from("12345")]),
      4,
    ),
    (error) => error instanceof LocalRequestError && error.statusCode === 413,
  );
});
