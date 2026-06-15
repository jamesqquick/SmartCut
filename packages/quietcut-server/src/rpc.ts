/**
 * JSON-RPC 2.0 over newline-delimited JSON on stdio.
 *
 * Wire format:
 *   - Every line on stdin/stdout is one JSON object.
 *   - Requests:        { jsonrpc, id, method, params }
 *   - Responses:       { jsonrpc, id, result }  OR  { jsonrpc, id, error }
 *   - Notifications:   { jsonrpc, method, params }   (no `id`)
 *
 * Logging always goes to stderr. Nothing other than protocol messages
 * may be written to stdout, or the client (Swift) will fail to parse.
 */

export type RpcId = number | string;

export type RpcRequest = {
  jsonrpc: "2.0";
  id: RpcId;
  method: string;
  params?: unknown;
};

export type RpcNotification = {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
};

export type RpcError = {
  code: number;
  message: string;
  data?: unknown;
};

export type RpcSuccess = {
  jsonrpc: "2.0";
  id: RpcId;
  result: unknown;
};

export type RpcFailure = {
  jsonrpc: "2.0";
  id: RpcId | null;
  error: RpcError;
};

export type RpcResponse = RpcSuccess | RpcFailure;

// Standard JSON-RPC 2.0 error codes plus a few app-specific ones.
export const RPC_ERROR = {
  parseError: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  invalidParams: -32602,
  internalError: -32603,
  // App-specific (reserved range: -32000 to -32099)
  jobAlreadyRunning: -32001,
  jobNotRunning: -32002,
  cancelled: -32003,
} as const;

export type Handler = (params: unknown) => Promise<unknown> | unknown;

/**
 * Maps method names to handlers. Dispatch is async; throwing a plain
 * Error becomes an `internalError` response. Throwing an `RpcDispatchError`
 * lets the handler set a custom code + message.
 */
export class RpcDispatcher {
  private readonly handlers = new Map<string, Handler>();

  register(method: string, handler: Handler): void {
    this.handlers.set(method, handler);
  }

  async dispatch(request: RpcRequest): Promise<RpcResponse> {
    const handler = this.handlers.get(request.method);
    if (!handler) {
      return {
        jsonrpc: "2.0",
        id: request.id,
        error: {
          code: RPC_ERROR.methodNotFound,
          message: `Method not found: ${request.method}`,
        },
      };
    }

    try {
      const result = await handler(request.params);
      return { jsonrpc: "2.0", id: request.id, result };
    } catch (err) {
      if (err instanceof RpcDispatchError) {
        return {
          jsonrpc: "2.0",
          id: request.id,
          error: { code: err.code, message: err.message, data: err.data },
        };
      }
      return {
        jsonrpc: "2.0",
        id: request.id,
        error: {
          code: RPC_ERROR.internalError,
          message: err instanceof Error ? err.message : String(err),
        },
      };
    }
  }
}

export class RpcDispatchError extends Error {
  constructor(
    public readonly code: number,
    message: string,
    public readonly data?: unknown,
  ) {
    super(message);
    this.name = "RpcDispatchError";
  }
}

/**
 * Parse a single line of JSON-RPC. Returns either a structured request,
 * a structured error response (for malformed input), or `null` when the
 * line is blank.
 */
export function parseRpcLine(
  line: string,
):
  | { kind: "request"; request: RpcRequest }
  | { kind: "error"; response: RpcFailure }
  | null {
  const trimmed = line.trim();
  if (trimmed === "") return null;

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return {
      kind: "error",
      response: {
        jsonrpc: "2.0",
        id: null,
        error: {
          code: RPC_ERROR.parseError,
          message: "Failed to parse JSON",
        },
      },
    };
  }

  if (!isPlainObject(parsed)) {
    return {
      kind: "error",
      response: {
        jsonrpc: "2.0",
        id: null,
        error: {
          code: RPC_ERROR.invalidRequest,
          message: "Request must be a JSON object",
        },
      },
    };
  }

  const obj = parsed as Record<string, unknown>;
  if (obj.jsonrpc !== "2.0" || typeof obj.method !== "string") {
    return {
      kind: "error",
      response: {
        jsonrpc: "2.0",
        id:
          typeof obj.id === "number" || typeof obj.id === "string"
            ? obj.id
            : null,
        error: {
          code: RPC_ERROR.invalidRequest,
          message: "Missing or invalid jsonrpc/method fields",
        },
      },
    };
  }

  if (obj.id === undefined) {
    // Notifications are not currently expected from the client; respond
    // with an error rather than silently dropping them.
    return {
      kind: "error",
      response: {
        jsonrpc: "2.0",
        id: null,
        error: {
          code: RPC_ERROR.invalidRequest,
          message: "Notifications are not supported by the server",
        },
      },
    };
  }

  if (typeof obj.id !== "number" && typeof obj.id !== "string") {
    return {
      kind: "error",
      response: {
        jsonrpc: "2.0",
        id: null,
        error: {
          code: RPC_ERROR.invalidRequest,
          message: "id must be a number or string",
        },
      },
    };
  }

  return {
    kind: "request",
    request: {
      jsonrpc: "2.0",
      id: obj.id,
      method: obj.method,
      params: obj.params,
    },
  };
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
