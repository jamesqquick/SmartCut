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
  // Inline all workspace deps so the Swift app can ship a single file.
  noExternal: ["quietcut-core"],
  banner: {
    js: "#!/usr/bin/env node",
  },
});
