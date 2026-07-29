import { defineConfig } from 'vitepress'

// Project page on GitHub Pages: https://keinstn.github.io/drover/
// `base` must stay '/drover/' — the privacy policy and support URLs derived
// from it are registered in App Store Connect and must not move.
const base = '/drover/'

export default defineConfig({
  base,
  title: 'Drover',
  description:
    'Supervise and steer AI coding agents running on your own computer, from your phone.',
  cleanUrls: false,
  // English lives at the root (`root` locale = no path prefix), so adding a
  // `ja` locale later is purely additive and never moves the English URLs.
  locales: {
    root: {
      label: 'English',
      lang: 'en',
    },
  },
  themeConfig: {
    nav: [
      { text: 'Support', link: '/support/' },
      { text: 'Privacy', link: '/privacy/' },
      { text: 'GitHub', link: 'https://github.com/keinstn/drover' },
    ],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/keinstn/drover' },
    ],
    // Raw HTML: hrefs here are NOT rewritten with `base`, so they carry it.
    footer: {
      message: `<a href="${base}privacy/">Privacy Policy</a> · <a href="${base}support/">Support</a> · <a href="https://github.com/keinstn/drover">GitHub</a>`,
      copyright: 'Copyright © 2026 Keisuke Nishitani',
    },
  },
})
