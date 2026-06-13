import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  guideSidebar: [
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
      label: 'How it works',
      items: [
        'reference/inventory-structure',
        'reference/graph-endpoints',
        'reference/diff-engine',
        'reference/activation-events',
      ],
    },
    {
      type: 'doc',
      id: 'contributing',
      label: 'Contributing',
    },
  ],
  customizeSidebar: [
    {
      type: 'doc',
      id: 'customize/index',
      label: 'Overview',
    },
    {
      type: 'category',
      label: 'Foundations',
      items: [
        'customize/environment-variables',
      ],
    },
    {
      type: 'category',
      label: 'Pipeline & Scheduling',
      items: [
        'customize/pipeline',
      ],
    },
    {
      type: 'category',
      label: 'Notifications',
      items: [
        'customize/notifications',
        'customize/email-notifications',
        'customize/webhook-channels',
        'customize/scan-errors',
        'customize/alert-fatigue',
      ],
    },
    {
      type: 'category',
      label: 'Reporting & Analysis',
      items: [
        'customize/reporting',
        'customize/expiring-assignments',
      ],
    },
    {
      type: 'category',
      label: 'Detection & Classification',
      items: [
        'customize/severity-rules',
        'customize/diff-engine',
        'customize/expected-changes',
      ],
    },
  ],
  accessModelSidebar: [
    'access-model/overview',
    'access-model/eam-role-catalog',
    'access-model/setup-compliance',
    'access-model/coverage-exclusions',
    'access-model/pim-groups',
    'access-model/auth-context-compliance',
  ],
};

export default sidebars;
