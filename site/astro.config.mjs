import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://ydah.github.io',
  base: '/flexr',
  integrations: [
    starlight({
      title: 'flexr',
      description: 'A Ruby-native lexer generator for parser authors.',
      customCss: ['./src/styles/custom.css'],
      sidebar: [
        {
          label: 'Learn',
          items: [
            { label: 'Getting started', slug: 'learn/getting-started' },
            { label: 'Runtime mode', slug: 'learn/runtime-mode' },
            { label: 'Generation', slug: 'learn/generation' },
            { label: 'Parser integration', slug: 'learn/parser-integration' }
          ]
        },
        {
          label: 'Concepts',
          items: [
            { label: 'Matching semantics', slug: 'concepts/matching-semantics' },
            { label: 'Runtime vs generated', slug: 'concepts/runtime-vs-generated' },
            { label: 'Regexp model', slug: 'concepts/regexp-model' },
            { label: 'Security model', slug: 'concepts/security-model' }
          ]
        },
        {
          label: 'Reference',
          items: [
            { label: 'DSL', slug: 'reference/dsl' },
            { label: 'Action context', slug: 'reference/action-context' },
            { label: 'Runtime', slug: 'reference/runtime' },
            { label: 'Tokens and locations', slug: 'reference/tokens-and-locations' },
            { label: 'CLI', slug: 'reference/cli' },
            { label: 'Regexp compatibility', slug: 'reference/regexp' },
            { label: 'Diagnostics', slug: 'reference/diagnostics' },
            { label: 'Public API', slug: 'reference/public-api' }
          ]
        },
        {
          label: 'Project',
          items: [
            { label: 'Examples', slug: 'examples' },
            { label: 'Benchmarks', slug: 'benchmarks' },
            { label: 'Changelog', slug: 'changelog' }
          ]
        }
      ],
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/ydah/flexr' }
      ]
    })
  ]
});
