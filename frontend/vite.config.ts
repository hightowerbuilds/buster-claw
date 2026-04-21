import { defineConfig } from "vite";
import solidPlugin from "vite-plugin-solid";

export default defineConfig({
  plugins: [solidPlugin()],
  build: {
    target: "esnext",
    outDir: "dist",
  },
  server: {
    origin: "http://localhost:5173",
    hmr: {
      host: "localhost",
      port: 5173,
      protocol: "ws",
    },
  },
});
