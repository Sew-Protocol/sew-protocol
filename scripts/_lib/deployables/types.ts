/** Shared types for the deployable-artifact export subsystem. */

export type ScopeHint = 'sew' | 'shared';
export type Category =
  | 'governance'
  | 'core'
  | 'yield'
  | 'resolution'
  | 'library'
  | 'infra'
  | 'ops';

export interface AllowlistEntry {
  artifactName: string;
  contractName: string;
  sourcePath: string;
  scopeHint: ScopeHint;
  category: Category;
  origin?: 'sew' | 'openzeppelin' | 'safe';
  notes?: string;
}

export interface Allowlist {
  schemaVersion: number;
  packageName: string;
  bundleVersion: string;
  buildArtifactSource: 'forge' | 'hardhat';
  buildProfile: string;
  entries: AllowlistEntry[];
}

export interface LinkReference {
  sourcePath: string;
  libraryName: string;
  references: Array<{ start: number; length: number }>;
}

/** Normalized linkReferences keyed by sourcePath -> libraryName -> offsets. */
export type LinkReferencesMap = Record<string, Record<string, Array<{ start: number; length: number }>>>;

export interface ForgeArtifact {
  contractName: string;
  sourcePath: string;
  abi: unknown[];
  bytecodeObject: string;
  deployedBytecodeObject: string;
  bytecodeLinkReferences: LinkReferencesMap;
  deployedLinkReferences: LinkReferencesMap;
  metadataBase64: string;
  metadata: unknown;
  compilerVersion: string;
  evmVersion: string;
  optimizerRuns: number;
  viaIR: boolean;
  methodIdentifiers: Record<string, string>;
}

export interface ManifestArtifactRecord {
  contractName: string;
  sourcePath: string;
  origin?: 'sew' | 'openzeppelin' | 'safe';
  scopeHint: ScopeHint;
  category: Category;
  artifactFile: string;
  abiSha256: string;
  creationBytecodeSha256: string;
  runtimeBytecodeSha256: string;
  fileSha256: string;
  hasLinkReferences: boolean;
  hasDeployedLinkReferences: boolean;
}

export interface Manifest {
  schemaVersion: number;
  packageName: string;
  bundleVersion: string;
  source: {
    repository: string;
    commit: string;
    commitSource: string;
    commitOverride: boolean;
    dirty: boolean;
  };
  build: {
    artifactSource: string;
    profile: string;
    compiler: { name: string; version: string };
    settings: {
      evmVersion: string;
      optimizerRuns: number;
      viaIR: boolean;
    };
  };
  artifacts: Record<string, ManifestArtifactRecord>;
  bundleRoot: string;
}

export interface ExportedArtifactFile {
  name: string;
  contractName: string;
  sourcePath: string;
  origin?: 'sew' | 'openzeppelin' | 'safe';
  scopeHint: ScopeHint;
  category: Category;
  abi: unknown[];
  bytecode: string;
  deployedBytecode: string;
  linkReferences: LinkReferencesMap;
  deployedLinkReferences: LinkReferencesMap;
  metadata: string;
}
