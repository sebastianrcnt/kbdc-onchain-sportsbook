import { build, context } from "esbuild";

const config = {
  entryPoints: ["src/main.js"],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: ["es2020"],
  outfile: "dist/app.js",
  sourcemap: true,
  logLevel: "info"
};

if (process.argv.includes("--watch")) {
  const ctx = await context(config);
  await ctx.watch();
  // Keep process alive in watch mode.
  process.stdin.resume();
} else {
  await build(config);
}
