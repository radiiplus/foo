/**
 * Tratio project configuration schema, version 1.
 * Independent of backend, compiler version, or standard library evolution.
 */
export interface Manifest {
  name: string;
  version: string;
  language: string;
  build?: Build;
  dependencies?: Record<string, string>;
}

export interface Build {
  type?: string;
  target?: string[];
  optimize?: string;
}