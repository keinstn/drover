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
    ja: {
      label: '日本語',
      lang: 'ja',
      description:
        '自分のコンピュータで動く AI コーディングエージェントを、スマートフォンから監督・操作できます。',
      // `socialLinks` and `title` are deliberately absent: per-locale
      // `themeConfig` is merged shallowly over root's, so omitted keys are
      // inherited and repeating them can only drift.
      themeConfig: {
        nav: [
          { text: 'サポート', link: '/ja/support/' },
          { text: 'プライバシー', link: '/ja/privacy/' },
          { text: 'GitHub', link: 'https://github.com/keinstn/drover' },
        ],
        outline: { label: 'このページの内容' },
        darkModeSwitchLabel: '外観',
        lightModeSwitchTitle: 'ライトテーマに切り替え',
        darkModeSwitchTitle: 'ダークテーマに切り替え',
        returnToTopLabel: 'トップへ戻る',
        langMenuLabel: '言語を変更',
        skipToContentLabel: '本文へスキップ',
        notFound: {
          title: 'ページが見つかりません',
          quote: 'お探しのページは移動または削除された可能性があります。',
          linkLabel: 'ホームへ',
          linkText: 'ホームに戻る',
        },
        // Raw HTML here too: these hrefs are NOT rewritten with `base`.
        footer: {
          message: `<a href="${base}ja/privacy/">プライバシーポリシー</a> · <a href="${base}ja/support/">サポート</a> · <a href="https://github.com/keinstn/drover">GitHub</a>`,
          copyright: 'Copyright © 2026 Keisuke Nishitani',
        },
      },
    },
    zh: {
      label: '简体中文',
      lang: 'zh-Hans',
      description: '在手机上监督和操控跑在你自己电脑上的 AI 编程智能体。',
      // Same as `ja`: `socialLinks` and `title` are deliberately absent so the
      // shallow merge over root's `themeConfig` keeps inheriting them.
      themeConfig: {
        nav: [
          { text: '支持', link: '/zh/support/' },
          // There is only one canonical privacy policy, the English one, and it
          // is the text registered in App Store Connect — so every locale's
          // privacy link points at `/privacy/`, never a translated copy.
          { text: '隐私政策', link: '/privacy/' },
          { text: 'GitHub', link: 'https://github.com/keinstn/drover' },
        ],
        outline: { label: '本页内容' },
        darkModeSwitchLabel: '外观',
        lightModeSwitchTitle: '切换到浅色主题',
        darkModeSwitchTitle: '切换到深色主题',
        returnToTopLabel: '回到顶部',
        langMenuLabel: '切换语言',
        skipToContentLabel: '跳到正文',
        notFound: {
          title: '找不到这个页面',
          quote: '你要找的页面可能已经移动或删除了。',
          linkLabel: '回到首页',
          linkText: '返回首页',
        },
        // Raw HTML here too: these hrefs are NOT rewritten with `base`. Note the
        // privacy href has no `zh/` — it is the English policy on purpose.
        footer: {
          message: `<a href="${base}privacy/">隐私政策（英文）</a> · <a href="${base}zh/support/">支持</a> · <a href="https://github.com/keinstn/drover">GitHub</a>`,
          copyright: 'Copyright © 2026 Keisuke Nishitani',
        },
      },
    },
  },
  // Markdown images only — the three band screenshots are below the fold and
  // were ~739 KB of the landing page's ~1.02 MB. The frontmatter `hero.image`
  // is rendered by the theme component, not markdown, so it stays eager.
  markdown: {
    image: { lazyLoading: true },
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
