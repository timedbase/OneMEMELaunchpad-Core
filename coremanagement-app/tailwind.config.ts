/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        bg:        '#07080F',
        surface:   '#0F1421',
        border:    '#1C2538',
        accent:    '#6366F1',
        'accent-2':'#4F46E5',
        danger:    '#F43F5E',
        ok:        '#10B981',
        warn:      '#F59E0B',
        text:      '#E8EDF8',
        muted:     '#64748B',
      },
      borderRadius: {
        DEFAULT: '8px',
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', '-apple-system', 'sans-serif'],
        mono: ['JetBrains Mono', 'Fira Code', 'Menlo', 'monospace'],
      },
    },
  },
  plugins: [],
}
