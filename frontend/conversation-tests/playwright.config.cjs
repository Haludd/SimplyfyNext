const { defineConfig } = require("@playwright/test");
module.exports = defineConfig({
  testDir: ".",
  testMatch: "*.spec.cjs",
  timeout: 45000,
  workers: 1,
  use: {
    baseURL: process.env.CONVERSATION_TEST_URL || "http://127.0.0.1:8000",
    headless: true,
  },
});
