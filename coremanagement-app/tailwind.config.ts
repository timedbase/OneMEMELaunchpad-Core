/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        bg: '#0d0d0f',
        surface: '#141417',
        border: '#242428',
        accent: '#f0b90b',
        'accent-2': '#e8a800',
        danger: '#e05252',
        ok: '#42b883',
        warn: '#f0a30b',
        text: '#e8e8ed',
        muted: '#7a7a8a',
      },
      borderRadius: {
        DEFAULT: '10px',
      },
    },
  },
  plugins: [],
}
