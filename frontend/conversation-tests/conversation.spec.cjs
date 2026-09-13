const { test, expect } = require("@playwright/test");
const jsQR = require("jsqr");
async function start(page) {
  await page.goto("/conversation");
  await page.locator("#name").fill("Alex");
  await page.locator("#create").click();
  await expect(page.locator("#connection")).toHaveText("Connected");
  return page.locator("#code-label").innerText();
}
async function join(page, code) {
  await page.goto(`/conversation?room=${code}`);
  await page.locator("#name").fill("Sam");
  await page.locator("#join").click();
  await expect(page.locator("#connection")).toHaveText("Connected");
}
async function send(page, text) {
  await page.locator("#draft").fill(text);
  await page.locator("#send").click();
}
async function bubble(page, text) {
  await expect(page.locator(".bubble", { hasText: text })).toHaveCount(1);
}

test("QR, two-device chat, JSON upload, repair, refresh and end", async ({
  page,
  browser,
}) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.setViewportSize({ width: 1440, height: 1050 });
  await page.goto("/conversation");
  await page.screenshot({ path: "test-results/lobby.png", fullPage: true });
  const code = await start(page);
  // Decode the actual rendered QR with an independent decoder.
  const pixels = await page.evaluate(async () => {
    const svg = document.querySelector("#qr svg");
    const image = new Image();
    image.width = image.height = 500;
    image.src = `data:image/svg+xml;base64,${btoa(new XMLSerializer().serializeToString(svg))}`;
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 500;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "white";
    ctx.fillRect(0, 0, 500, 500);
    ctx.drawImage(image, 0, 0, 500, 500);
    return Array.from(ctx.getImageData(0, 0, 500, 500).data);
  });
  expect(jsQR(new Uint8ClampedArray(pixels), 500, 500)?.data).toBe(page.url());
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
  });
  const other = await context.newPage();
  other.on("pageerror", (e) => errors.push(e.message));
  await join(other, code);
  await send(page, "Can you help me?");
  await bubble(other, "Can you help me?");
  await send(other, "Of course!");
  await bubble(page, "Of course!");
  await page.locator(".integration summary").click();
  await page.locator("#sample").click();
  await bubble(other, "HELLO");
  await page.locator("#uncertain").click();
  await expect(page.locator(".repair .bubble")).toContainText("Please repeat");
  await expect(other.locator(".repair .bubble")).toContainText(
    "Clarifying a sign",
  );
  const file = Buffer.from(
    JSON.stringify({
      words: [
        { word: "THANK", confidence: 0.96 },
        { word: "YOU", confidence: 0.95 },
      ],
    }),
  );
  await page
    .locator("#words-file")
    .setInputFiles({
      name: "words.json",
      mimeType: "application/json",
      buffer: file,
    });
  await bubble(other, "THANK YOU");
  await page.screenshot({
    path: "test-results/conversation-desktop.png",
    fullPage: true,
  });
  await other.screenshot({
    path: "test-results/conversation-mobile.png",
    fullPage: true,
  });
  expect(
    await other.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await other.reload();
  await expect(other.locator("#connection")).toHaveText("Connected");
  await expect(other.locator(".message")).toHaveCount(5);
  await bubble(other, "HELLO");
  page.on("dialog", (d) => d.accept());
  await page.locator("#end").click();
  await expect(other.locator("#ended")).toBeVisible();
  expect(errors).toEqual([]);
  await context.close();
});

test("lost acknowledgement and reconnect do not duplicate messages", async ({
  page,
  browser,
}) => {
  const code = await start(page);
  const context = await browser.newContext();
  const other = await context.newPage();
  await join(other, code);
  let interrupted = false;
  await page.route("**/messages", async (route) => {
    if (!interrupted) {
      interrupted = true;
      await route.fetch();
      await route.abort();
    } else await route.continue();
  });
  await send(page, "One message only");
  await bubble(other, "One message only");
  const input = {
    message_id: "510ea3cd-e93d-4cdb-9948-1cc9e03de969",
    words: [{ word: "HELLO", confidence: 0.9 }],
  };
  await page.evaluate(
    (data) => window.signBridgeConversation.submitWords(data),
    input,
  );
  await bubble(other, "HELLO");
  await page.evaluate(
    (data) => window.signBridgeConversation.submitWords(data),
    input,
  );
  await expect(page.locator("#outbox")).toBeEmpty();
  await context.setOffline(true);
  await send(page, "While you were away");
  await context.setOffline(false);
  await bubble(other, "While you were away");
  await expect(other.locator(".message")).toHaveCount(3);
  await context.close();
});

test("speech drafts and TTS lifecycle with deterministic browser doubles", async ({
  page,
  browser,
}) => {
  const code = await start(page);
  const context = await browser.newContext();
  await context.addInitScript(() => {
    window.testSpoken = [];
    class Recognition {
      start() {
        window.testRecognition = this;
      }
      stop() {
        this.onend?.();
      }
      abort() {
        this.onend?.();
      }
    }
    window.SpeechRecognition = Recognition;
    Object.defineProperty(window, "speechSynthesis", {
      value: {
        cancel() {},
        speak(utterance) {
          window.testSpoken.push(utterance.text);
        },
      },
    });
  });
  const other = await context.newPage();
  await join(other, code);
  await other.locator("#microphone").click();
  await other.evaluate(() =>
    window.testRecognition.onresult({
      results: [[{ transcript: "Hello from speech" }]],
    }),
  );
  await expect(other.locator("#draft")).toHaveValue("Hello from speech");
  await expect(other.locator("#send")).toBeDisabled();
  await other.locator("#microphone").click();
  await other.locator("#send").click();
  await bubble(page, "Hello from speech");
  await other.locator("#auto-speak").check();
  await page.evaluate(() =>
    window.signBridgeConversation.submitWords({
      words: [{ word: "HELLO", confidence: 0.9 }],
    }),
  );
  await expect
    .poll(() => other.evaluate(() => window.testSpoken))
    .toEqual(["HELLO"]);
  await other.reload();
  await expect(other.locator("#connection")).toHaveText("Connected");
  expect(await other.evaluate(() => window.testSpoken)).toEqual([]);
  await context.close();
});
