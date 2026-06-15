import { defineConfig } from "tsup";

export default defineConfig({
  // Named entry → output basename `server.cjs` (not `index.cjs`).
  entry: { server: "src/index.ts" },
  // CJS so Swift can launch with `node /path/to/server.cjs` without
  // worrying about ESM resolution rules.
  format: ["cjs"],
  outExtension: () => ({ js: ".cjs" }),
  target: "node20",
  clean: true,
  shims: false,
  // Inline all deps (workspace + third-party) so the Swift app can spawn
  // server.cjs as a fully self-contained file with no node_modules lookup.
  noExternal: [/.*/],
  banner: {
    js: "#!/usr/bin/env node",
  },
});
