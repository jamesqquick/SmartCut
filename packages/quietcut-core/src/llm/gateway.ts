import Anthropic from "@anthropic-ai/sdk";

// ---------------------------------------------------------------------------
// Anthropic client routed through Cloudflare AI Gateway.
//
// Base URL: https://gateway.ai.cloudflare.com/v1/{account}/{gateway}/anthropic
// We use the official Anthropic SDK with a custom baseURL so requests flow
// through the gateway (observability, caching, rate limiting) while keeping the
// standard Messages API.
//
// Two auth modes are supported:
//   - "byok"  : your Anthropic key (ANTHROPIC_API_KEY) is sent as x-api-key.
//               CF_AIG_TOKEN is optional (required only for authenticated
//               gateways) and added as cf-aig-authorization.
//   - "unified": Cloudflare holds the provider key (BYOK / Unified Billing).
//               No Anthropic key is sent; auth is the gateway token alone
//               (cf-aig-authorization), and x-api-key is explicitly omitted.
// ---------------------------------------------------------------------------

export type GatewayEnv = {
  accountId: string;
  gatewayId: string;
  anthropicApiKey?: string;
  gatewayToken?: string;
  mode: "byok" | "unified";
};

/**
 * Read and validate the env vars required to reach Anthropic via AI Gateway.
 * Throws a single error describing what is missing.
 */
export function resolveGatewayEnv(): GatewayEnv {
  const anthropicApiKey = process.env.ANTHROPIC_API_KEY || undefined;
  const accountId = process.env.CLOUDFLARE_ACCOUNT_ID || undefined;
  const gatewayId = process.env.CF_AIG_GATEWAY_ID || undefined;
  const gatewayToken = process.env.CF_AIG_TOKEN || undefined;

  const missing: string[] = [];
  if (!accountId) missing.push("CLOUDFLARE_ACCOUNT_ID");
  if (!gatewayId) missing.push("CF_AIG_GATEWAY_ID");

  // Auth: need either an Anthropic key (BYOK in-request) or a gateway token
  // (Unified Billing / stored keys).
  const hasAuth = Boolean(anthropicApiKey || gatewayToken);

  if (missing.length > 0 || !hasAuth) {
    const lines = [
      "Could not configure Cloudflare AI Gateway access.",
      "",
      "Required:",
      "  CLOUDFLARE_ACCOUNT_ID - Cloudflare account ID",
      "  CF_AIG_GATEWAY_ID     - the AI Gateway name/ID",
      "",
      "Plus ONE of these auth methods:",
      "  ANTHROPIC_API_KEY     - your Anthropic key (sent through the gateway), or",
      "  CF_AIG_TOKEN          - gateway token, when Cloudflare holds the provider",
      "                          key (Unified Billing / stored keys / authenticated gateway)",
    ];
    if (missing.length > 0) {
      lines.push("", `Missing: ${missing.join(", ")}`);
    }
    if (!hasAuth) {
      lines.push(
        "",
        "No auth method found: set ANTHROPIC_API_KEY or CF_AIG_TOKEN."
      );
    }
    throw new Error(lines.join("\n"));
  }

  return {
    accountId: accountId!,
    gatewayId: gatewayId!,
    anthropicApiKey,
    gatewayToken,
    // Prefer the in-request Anthropic key when present; otherwise use the
    // gateway token (Unified Billing).
    mode: anthropicApiKey ? "byok" : "unified",
  };
}

/**
 * Build an Anthropic client pointed at the AI Gateway endpoint.
 */
export function createGatewayClient(env: GatewayEnv): Anthropic {
  const baseURL = `https://gateway.ai.cloudflare.com/v1/${env.accountId}/${env.gatewayId}/anthropic`;

  // `null` header values tell the SDK a header is intentionally omitted.
  const defaultHeaders: Record<string, string | null> = {};
  if (env.gatewayToken) {
    defaultHeaders["cf-aig-authorization"] = `Bearer ${env.gatewayToken}`;
  }

  if (env.mode === "unified") {
    // Cloudflare injects the provider key; do not send x-api-key.
    defaultHeaders["x-api-key"] = null;
    return new Anthropic({
      apiKey: null,
      baseURL,
      defaultHeaders,
    });
  }

  return new Anthropic({
    apiKey: env.anthropicApiKey!,
    baseURL,
    defaultHeaders,
  });
}
