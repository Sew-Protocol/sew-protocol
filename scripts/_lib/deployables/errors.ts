/** Minimal error type for the deployable-export subsystem. */
export class ConfigError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly details?: Record<string, unknown>,
  ) {
    super(message);
    this.name = 'ConfigError';
  }
}
