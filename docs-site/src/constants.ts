import defaults from './data/eam-catalog-defaults.json';

// release-please only rewrites a version that carries this marker, same as in VERSION.
export const APP_VERSION = '0.4.0'; // x-release-please-version

// Version of the EAM role catalog content, from the same file the published catalog is built from.
export const CATALOG_VERSION: string = defaults.catalogVersion;
