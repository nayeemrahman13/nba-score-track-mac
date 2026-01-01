/** @type {import('tailwindcss').Config} */
export default {
    content: [
        "./index.html",
        "./src/**/*.{js,ts,jsx,tsx}",
    ],
    darkMode: "class",
    theme: {
        extend: {
            colors: {
                // macOS Dark Mode Palette approximation
                "app-bg": "rgba(30, 30, 30, 0.70)",
                "app-border": "rgba(255, 255, 255, 0.12)",
                "card-bg": "rgba(255, 255, 255, 0.06)",
                "card-hover": "rgba(255, 255, 255, 0.1)",
                "control-bg": "rgba(118, 118, 128, 0.24)", // macOS segmented control track
                "control-active": "rgba(99, 99, 102, 1)", // macOS segmented control active
                "primary": "#0A84FF", // macOS System Blue
                "danger": "#FF453A", // macOS System Red
                "secondary": "#8E8E93", // macOS System Gray
            },
            fontFamily: {
                "sans": ["-apple-system", "BlinkMacSystemFont", "Segoe UI", "Roboto", "Helvetica", "Arial", "sans-serif"],
            },
            fontSize: {
                "xxs": "0.65rem",
            },
            boxShadow: {
                "macos": "0 20px 40px rgba(0,0,0,0.4), 0 0 0 1px rgba(255,255,255,0.1) inset",
                "control": "0 1px 2px rgba(0,0,0,0.2)",
            }
        },
    },
    plugins: [],
}
