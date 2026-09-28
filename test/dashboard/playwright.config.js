const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: __dirname,
  timeout: 30000,
  fullyParallel: false,
  workers: 1,
  use: {
    headless: true
  }
});
