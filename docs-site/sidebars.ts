import type {SidebarsConfig} from '@docusaurus/types';

const sidebars: SidebarsConfig = {
  docsSidebar: [
    {
      type: 'doc',
      id: 'intro',
    },
    {
      type: 'category',
      label: 'Getting Started',
      items: [
        'getting-started/prerequisites',
        'getting-started/local-testing',
        {
          type: 'category',
          label: 'Deployment',
          items: [
            'getting-started/installation',
            'getting-started/installation-github',
          ],
        },
        'getting-started/faq',
      ],
    },
    {
      type: 'category',
      label: 'Configuration',
      items: [
        'configuration/pipeline-yaml',
        'configuration/notifications',
        'configuration/severity-rules',
        'configuration/alert-fatigue',
      ],
    },
    {
      type: 'category',
      label: 'Reference',
      items: [
        'reference/inventory-structure',
        'reference/graph-endpoints',
        'reference/diff-engine',
        'reference/activation-events',
      ],
    },
  ],
  customizeSidebar: [
    {
      type: 'doc',
      id: 'customize/index',
      label: 'Overview',
    },
    'customize/expected-changes',
    'customize/severity-rules',
    'customize/pipeline',
    'customize/diff-engine',
    'customize/notifications',
    {
      type: 'doc',
      id: 'contributing',
      label: 'Contributing',
    },
  ],
};

export default sidebars;
