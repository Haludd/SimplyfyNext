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

async function showRoomWithoutConnecting(page) {
  await page.evaluate(() => {
    document.querySelector("#lobby").hidden = true;
    document.querySelector("#room").hidden = false;
  });
}

async function layoutSnapshot(page) {
  return page.evaluate(() => {
    const isRendered = (element) => {
      const style = getComputedStyle(element);
      const bounds = element.getBoundingClientRect();
      return (
        style.display !== "none" &&
        style.visibility !== "hidden" &&
        bounds.width > 0 &&
        bounds.height > 0
      );
    };
    const bounds = (selector) => {
      const rect = document.querySelector(selector).getBoundingClientRect();
      return {
        left: rect.left,
        right: rect.right,
        top: rect.top,
        bottom: rect.bottom,
        width: rect.width,
        height: rect.height,
      };
    };
    const tooSmallTouchTargets = [...document.querySelectorAll("button, summary")]
      .filter(isRendered)
      .map((element) => {
        const rect = element.getBoundingClientRect();
        return {
          name: element.id || element.textContent.trim().replace(/\s+/g, " "),
          width: rect.width,
          height: rect.height,
        };
      })
      .filter(({ width, height }) => width < 43.5 || height < 43.5);
    const undersizedFormText = [
      ...document.querySelectorAll(
        'input:not([type="radio"]):not([type="checkbox"]):not([type="file"]), textarea, select',
      ),
    ]
      .filter(isRendered)
      .map((element) => ({
        name: element.id,
        fontSize: Number.parseFloat(getComputedStyle(element).fontSize),
      }))
      .filter(({ fontSize }) => fontSize < 16);

    return {
      horizontalOverflow:
        document.documentElement.scrollWidth - document.documentElement.clientWidth,
      entryCard: bounds(".entry-card"),
      roomLayout: bounds(".room-layout"),
      chat: bounds(".chat"),
      roomDisplay: getComputedStyle(document.querySelector(".room-layout")).display,
      tooSmallTouchTargets,
      undersizedFormText,
    };
  });
}

function expectInsideViewport(box, viewportWidth) {
  expect(box.left).toBeGreaterThanOrEqual(-0.5);
  expect(box.right).toBeLessThanOrEqual(viewportWidth + 0.5);
}

const responsiveViewports = [
  { name: "small phone portrait", width: 320, height: 568, touch: true },
  { name: "phone portrait", width: 390, height: 844, touch: true },
  { name: "large phone portrait", width: 412, height: 915, touch: true },
  { name: "phone landscape", width: 844, height: 390, touch: true },
  { name: "tablet portrait", width: 768, height: 1024, touch: true },
  { name: "compact laptop", width: 1024, height: 768, touch: false },
  { name: "laptop", width: 1440, height: 900, touch: false },
];

test("conversation layout is responsive from small phones to laptops", async ({
  page,
}) => {
  for (const viewport of responsiveViewports) {
    await test.step(viewport.name, async () => {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await page.goto("/conversation");
      await expect(page.locator("#lobby")).toBeVisible();

      let snapshot = await layoutSnapshot(page);
      expect(snapshot.horizontalOverflow).toBeLessThanOrEqual(1);
      expectInsideViewport(snapshot.entryCard, viewport.width);

      await showRoomWithoutConnecting(page);
      snapshot = await layoutSnapshot(page);
      expect(snapshot.horizontalOverflow).toBeLessThanOrEqual(1);
      expectInsideViewport(snapshot.roomLayout, viewport.width);
      expectInsideViewport(snapshot.chat, viewport.width);

      if (viewport.width <= 720) {
        expect(snapshot.roomDisplay).toBe("flex");
      } else {
        expect(snapshot.roomDisplay).toBe("grid");
      }
      if (viewport.touch) {
        expect(snapshot.tooSmallTouchTargets).toEqual([]);
        expect(snapshot.undersizedFormText).toEqual([]);
      }
    });
  }
});

test("phone composer remains reachable when the virtual keyboard reduces height", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/conversation");
  await showRoomWithoutConnecting(page);

  await page.setViewportSize({ width: 390, height: 500 });
  const draft = page.locator("#draft");
  await draft.focus();
  await draft.scrollIntoViewIfNeeded();
  const bounds = await draft.boundingBox();

  expect(bounds).not.toBeNull();
  expect(bounds.y + bounds.height).toBeLessThanOrEqual(501);
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    ),
  ).toBeLessThanOrEqual(1);
});

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
