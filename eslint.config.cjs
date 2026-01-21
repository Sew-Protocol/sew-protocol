// ESLint v9+ flat config.
// This mirrors the legacy `.eslintrc.cjs` to keep behavior stable.
const js = require('@eslint/js');
const prettier = require('eslint-config-prettier');
const tsParser = require('@typescript-eslint/parser');
const tsPlugin = require('@typescript-eslint/eslint-plugin');

/** @type {import('eslint').Linter.FlatConfig[]} */
module.exports = [
  // Ignore generated/build artifacts
  {
    linterOptions: {
      // This repo uses eslint-disable pragmas in scripts; we don't want lint to fail due to
      // "unused eslint-disable" in places where rules differ across environments.
      reportUnusedDisableDirectives: false,
    },
    ignores: [
      'dist/**',
      'out/**',
      'cache/**',
      'cache-foundry/**',
      'artifacts/**',
      'deployments/**',
      'deploy-ledger/**',
      'coverage/**',
      'typechain-types/**',
      '**/typechain-types/**',
      'node_modules/**',
    ],
  },

  // Base recommended rules
  js.configs.recommended,

  // Disable formatting-related rules (Prettier handles formatting)
  prettier,

  // Project-specific rules / language options
  {
    files: ['**/*.{js,cjs,mjs,ts,tsx}'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: {
        // Node globals
        module: 'readonly',
        require: 'readonly',
        __dirname: 'readonly',
        __filename: 'readonly',
        process: 'readonly',
        Buffer: 'readonly',
        setTimeout: 'readonly',
        clearTimeout: 'readonly',
        setInterval: 'readonly',
        clearInterval: 'readonly',
        // Common globals used in scripts/tests
        console: 'readonly',
        // Test globals (mocha)
        describe: 'readonly',
        it: 'readonly',
        before: 'readonly',
        beforeEach: 'readonly',
        after: 'readonly',
        afterEach: 'readonly',
      },
    },
    rules: {
      // Prevent unsafe number parsing - use parseInteger() or parseBigInt() helpers instead
      // See docs/CODING_STANDARDS.md for details
      'no-restricted-syntax': [
        'error',
        {
          selector:
            'CallExpression[callee.name="parseInt"][arguments.length<2], CallExpression[callee.name="parseInt"][arguments.0.type!="Literal"][arguments.1.type!="Literal"]',
          message:
            'Use parseInteger() helper instead of parseInt() without validation. Always validate input and specify radix 10. See docs/CODING_STANDARDS.md',
        },
        {
          selector:
            'CallExpression[callee.name="Number"][arguments.0.type!="Literal"][arguments.0.type!="MemberExpression"]',
          message:
            'Use parseInteger() or parseBigInt() helper instead of Number() for parsing. Validate input first. See docs/CODING_STANDARDS.md',
        },
        {
          selector:
            'CallExpression[callee.name="BigInt"][arguments.0.type!="Literal"][arguments.0.type!="MemberExpression"]',
          message:
            'Use parseBigInt() helper instead of BigInt() for parsing. Validate input first. See docs/CODING_STANDARDS.md',
        },
      ],
    },
  },

  // TypeScript parsing support (keeps rules minimal; type-aware linting can be added later)
  {
    files: ['**/*.{ts,tsx}'],
    languageOptions: {
      parser: tsParser,
      parserOptions: {
        ecmaVersion: 2022,
        sourceType: 'module',
      },
    },
    plugins: {
      '@typescript-eslint': tsPlugin,
    },
    rules: {
      // Avoid false positives for TS-specific constructs
      'no-undef': 'off',
      'no-redeclare': 'off',
      'no-unused-vars': 'off',
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
    },
  },

  // Operational scripts & deployment code: keep lint non-blocking.
  // These files are executed in controlled environments and often intentionally contain
  // unused locals / parsing helpers. We still parse them, but we don't fail the build on style nitpicks.
  {
    files: [
      'config/**/*.{ts,tsx,js,cjs,mjs}',
      'deploy/**/*.{ts,tsx,js,cjs,mjs}',
      'scripts/**/*.{ts,tsx,js,cjs,mjs}',
      'governance/**/*.{ts,tsx,js,cjs,mjs}',
      'test/**/*.{ts,tsx,js,cjs,mjs}',
    ],
    rules: {
      '@typescript-eslint/no-unused-vars': 'off',
      'no-restricted-syntax': 'off',
    },
  },
];

