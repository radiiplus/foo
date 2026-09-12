/**
 * The stable, versioned Intermediate Representation root.
 * No backend-specific concepts exist here.
 */
export interface Module {
  name: string;
  version: string;
}