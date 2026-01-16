/** @type {import('eslint').Linter.Config} */
module.exports = {
  root: true,
  env: { node: true, es2022: true },
  parserOptions: { ecmaVersion: 2022, sourceType: 'module' },
  extends: ['eslint:recommended', 'prettier'],
  ignorePatterns: [
    'dist/**',
    'out/**',
    'cache/**',
    'artifacts/**',
    'deployments/**',
    'deploy-ledger/**',
  ],
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
};
