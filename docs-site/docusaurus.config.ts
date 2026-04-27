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

  plugins: [
    [
      require.resolve('@easyops-cn/docusaurus-search-local'),
      {
        hashed: true,
        docsRouteBasePath: '/docs',
        highlightSearchTermsOnTargetPage: true,
      },
    ],
  ],

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          editUrl: 'https://github.com/joel-prins/PIM-Monitor/tree/main/docs-site',
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
        name: 'og:title',
        content: 'PIM Monitor',
      },
      {
        name: 'og:description',
        content: 'Continuous monitoring of Microsoft Entra ID PIM state with git-based audit trail',
      },
      {
        name: 'og:image',
        content: 'https://pimmonitor.com/img/logo-dark-wordmark.png',
      },
      {
        name: 'og:type',
        content: 'website',
      },
      {
        name: 'og:url',
        content: 'https://pimmonitor.com',
      },
      {
        name: 'twitter:card',
        content: 'summary_large_image',
      },
      {
        name: 'twitter:title',
        content: 'PIM Monitor',
      },
      {
        name: 'twitter:description',
        content: 'Continuous monitoring of Microsoft Entra ID PIM state with git-based audit trail',
      },
      {
        name: 'twitter:image',
        content: 'https://pimmonitor.com/img/logo-dark-wordmark.png',
      },
      {
        name: 'robots',
        content: 'index, follow, max-snippet:-1, max-image-preview:large, max-video-preview:-1',
      },
    ],
    image: 'img/logo-dark-wordmark.png',
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
          sidebarId: 'docsSidebar',
          position: 'left',
          label: 'Docs',
        },
        {
          type: 'docSidebar',
          sidebarId: 'customizeSidebar',
          position: 'left',
          label: 'Customize',
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
              label: 'Configuration',
              to: '/docs/configuration/pipeline-yaml',
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
