import React from 'react';
import Head from '@docusaurus/Head';

/**
 * Injects a JSON-LD structured-data block into the page <head>.
 *
 * The site-wide Organization, WebSite, WebPage, and BreadcrumbList schemas are
 * produced by @stackql/docusaurus-plugin-structured-data. Use this component
 * only for page-specific schema that the plugin does not generate, such as
 * SoftwareApplication, FAQPage, HowTo, or DefinedTermSet.
 *
 * Pass a plain schema.org object (or array of objects) via the `schema` prop.
 */
export default function JsonLd({schema}: {schema: object | object[]}): JSX.Element {
  return (
    <Head>
      <script type="application/ld+json">{JSON.stringify(schema)}</script>
    </Head>
  );
}
