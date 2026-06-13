import {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: 'PIM Monitor',
  tagline: 'Continuous monitoring of Microsoft Entra ID PIM state with git-based audit trail',
  favicon: 'img/favicon.svg',

  url: 'https://pimmonitor.com',
  baseUrl: '/',
  organizationName: 'joel-prins',
  projectName: 'PIM-Monitor',

  onBrokenLinks: 'throw',

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'throw',
    },
  },

  plugins: [
    [
      require.resolve('@easyops-cn/docusaurus-search-local'),
      {
        hashed: true,
        docsRouteBasePath: '/docs',
        highlightSearchTermsOnTargetPage: true,
        indexBlog: false,
      },
    ],
    '@stackql/docusaurus-plugin-structured-data',
    [
      '@signalwire/docusaurus-plugin-llms-txt',
      {
        siteTitle: 'PIM Monitor',
        siteDescription:
          'PIM Monitor is an open-source pipeline that continuously monitors Microsoft Entra ID Privileged Identity Management (PIM). It diffs the live state of directory roles, eligibility and assignment schedules, PIM policies, and group membership against versioned inventory files, commits every change as a git audit trail, classifies changes by severity, and sends notifications. An optional Access Model layer enforces desired-state PIM policy compliance per role against the Enterprise Access Model.',
        depth: 2,
        content: {
          includePages: true,
          enableLlmsFullTxt: true,
        },
      },
    ],
  ],

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          editUrl: 'https://github.com/joel-prins/PIM-Monitor/tree/main/docs-site/docs',
          showLastUpdateTime: true,
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],


  themeConfig: {
    metadata: [
      {
        name: 'description',
        content: 'PIM Monitor: Continuous monitoring of Microsoft Entra ID PIM state with git-based audit trail. Track privileged identity management changes, detect unauthorized modifications, and maintain compliance.',
      },
      {
        name: 'keywords',
        content: 'PIM, Privileged Identity Management, Entra ID, Azure AD, monitoring, audit trail, security, compliance',
      },
      {
        name: 'og:type',
        content: 'website',
      },
      {
        name: 'twitter:card',
        content: 'summary_large_image',
      },
      {
        name: 'robots',
        content: 'index, follow, max-snippet:-1, max-image-preview:large, max-video-preview:-1',
      },
    ],
    image: 'img/logo-dark-wordmark.png',
    structuredData: {
      excludedRoutes: ['/search'],
      verbose: false,
      featuredImageDimensions: {
        width: 1200,
        height: 627,
      },
      authors: {},
      organization: {
        name: 'PIM Monitor',
        description:
          'Open-source pipeline for continuous monitoring of Microsoft Entra ID Privileged Identity Management (PIM), with a git-based audit trail and desired-state policy compliance.',
        sameAs: [
          'https://github.com/joel-prins/PIM-Monitor',
          'https://pimmanager.com',
        ],
      },
      website: {
        datePublished: '2025-01-01',
        inLanguage: 'en-US',
      },
      webpage: {
        datePublished: '2025-01-01',
        inLanguage: 'en-US',
      },
      breadcrumbLabelMap: {
        docs: 'Docs',
        'access-model': 'Access Model',
        'getting-started': 'Getting Started',
        customize: 'Customize',
        reference: 'Reference',
      },
    },
    navbar: {
      logo: {
        alt: 'PIM Monitor',
        src: 'img/logo-light.png',
        srcDark: 'img/logo-dark.png',
      },
      items: [
        {
          to: '/',
          label: 'Home',
          position: 'left',
        },
        {
          type: 'docSidebar',
          sidebarId: 'guideSidebar',
          position: 'left',
          label: 'Guide',
        },
        {
          type: 'docSidebar',
          sidebarId: 'customizeSidebar',
          position: 'left',
          label: 'Customize',
        },
        {
          type: 'docSidebar',
          sidebarId: 'accessModelSidebar',
          position: 'left',
          label: 'Access Model',
        },
        {
          href: 'https://github.com/joel-prins/PIM-Monitor',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Docs',
          items: [
            {
              label: 'Getting Started',
              to: '/docs/getting-started/prerequisites',
            },
            {
              label: 'Customize',
              to: '/docs/customize/',
            },
          ],
        },
        {
          title: 'More',
          items: [
            {
              label: 'GitHub Issues',
              href: 'https://github.com/joel-prins/PIM-Monitor/issues',
            },
            {
              label: 'Contributing',
              to: '/docs/contributing',
            },
          ],
        },
        {
          title: 'PIM Manager',
          items: [
            {
              label: 'pimmanager.com',
              href: 'https://pimmanager.com',
            },
          ],
        },
        {
          title: 'Author',
          items: [
            {
              label: 'Joël Prins on LinkedIn',
              href: 'https://www.linkedin.com/in/jo%C3%ABl-prins-4b4655aa/',
            },
          ],
        },
      ],
      copyright: `Built by <a href="https://www.linkedin.com/in/jo%C3%ABl-prins-4b4655aa/" target="_blank" rel="noopener noreferrer">Joël Prins</a> · <a href="https://docusaurus.io" target="_blank" rel="noopener noreferrer">Docusaurus</a>`,
    },
    prism: {
      theme: require('prism-react-renderer').themes.palenight,
      darkTheme: require('prism-react-renderer').themes.dracula,
      additionalLanguages: ['powershell', 'json', 'yaml', 'bash'],
    },
    colorMode: {
      defaultMode: 'dark',
      respectPrefersColorScheme: true,
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
