import type { Plugin } from 'vite';
import { defineConfig } from 'vitest/config';

/**
 * Vite resolves `node:sqlite` by stripping the prefix and hunting for a package
 * called "sqlite" — Node exposes this builtin under the prefixed name only, so
 * the lookup fails. Mark it external and let Node load it.
 */
function nodeSqliteExternal(): Plugin {
  return {
    name: 'node-sqlite-external',
    enforce: 'pre',
    resolveId(source) {
      if (source === 'node:sqlite' || source === 'sqlite') {
        return { id: 'node:sqlite', external: true };
      }
      return null;
    },
  };
}

export default defineConfig({
  plugins: [nodeSqliteExternal()],
  test: {
    environment: 'node',
    include: ['test/**/*.test.ts'],
    globals: false,
    env: {
      // Keep request/issue logs out of the test output.
      LOG_LEVEL: 'error',
    },
  },
});
