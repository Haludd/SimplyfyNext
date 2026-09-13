/* SignBridge conversation UI. No frames or landmarks cross this boundary. */
"use strict";
const $ = (id) => document.getElementById(id);
const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
let credentials = null,
  socket = null,
  snapshot = null,
  retryTimer = null,
  heartbeat = null;
let stopped = false,
  retries = 0,
  outbox = [],
  flushing = false,
  initialSnapshot = true;
let inputMode = "sign",
  draftSource = "text",
  recognition = null,
  listening = false;
let cameraStream = null,
  cameraStarting = false,
  cameraRevision = 0,
  typingAt = 0;
const finalMessages = new Set();
const params = new URLSearchParams(location.search);
const invitedCode = (params.get("room") || "").toUpperCase();
const sessionKey = (code) => `signbridge-room:${code}`;
function notice(text) {
  $("notice").textContent = text;
  $("notice").hidden = !text;
}
function storageRead(key) {
  try {
    return JSON.parse(sessionStorage.getItem(key));
  } catch {
    return null;
  }
}
function persist() {
  if (!credentials) return;
  try {
    sessionStorage.setItem(
      sessionKey(credentials.code),
      JSON.stringify({ credentials, outbox }),
    );
  } catch {
    notice(
      "This browser cannot save this tab’s connection. Keep this page open.",
    );
  }
}
function uuid() {
  // getRandomValues also works during a plain HTTP LAN text-only demonstration.
  if (crypto.randomUUID) return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
async function api(path, method = "GET", body, authenticated = true) {
  const response = await fetch(path, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(authenticated && credentials
        ? { Authorization: `Bearer ${credentials.token}` }
        : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(20000),
  });
  if (!response.ok) {
    let data;
    try {
      data = await response.json();
    } catch {
      data = {};
    }
    const error = new Error(
      typeof data.detail === "string"
        ? data.detail
        : "Invalid input. Check the words, confidence scores, and message ID.",
    );
    error.status = response.status;
    throw error;
  }
  return response.status === 204 ? null : response.json();
}
function route(suffix = "") {
  return `/api/rooms/${credentials.code}${suffix}`;
}
function connection(text, online = false) {
  $("connection").textContent = text;
  $("connection").classList.toggle("online", online);
}
async function enter(join) {
  const name = $("name").value.trim();
  if (!name) {
    notice("Please enter your name first.");
    $("name").focus();
    return;
  }
  const mode = document.querySelector('input[name="mode"]:checked').value;
  $("create").disabled = $("join").disabled = true;
  notice("");
  try {
    credentials = await api(
      join ? "/api/rooms/join" : "/api/rooms",
      "POST",
      {
        name,
        mode,
        ...(join ? { code: $("room-code").value.trim().toUpperCase() } : {}),
      },
      false,
    );
    outbox = [];
    startRoom(mode);
  } catch (error) {
    notice(error.message);
  } finally {
    $("create").disabled = $("join").disabled = false;
  }
}
function startRoom(mode) {
  stopped = false;
  snapshot = null;
  initialSnapshot = true;
  finalMessages.clear();
  $("lobby").hidden = true;
  $("ended").hidden = true;
  $("room").hidden = false;
  history.replaceState(null, "", `/conversation?room=${credentials.code}`);
  $("code-label").textContent = credentials.code;
  const inviteLink = `${location.origin}/conversation?room=${credentials.code}`;
  const qr = qrcode(0, "M");
  qr.addData(inviteLink);
  qr.make();
  // Only locally generated QR markup, never participant text, enters innerHTML.
  $("qr").innerHTML = qr.createSvgTag({
    cellSize: 4,
    margin: 16,
    scalable: true,
  });
  setMode(mode);
  persist();
  renderOutbox();
  connect();
  if (location.hostname === "localhost" || location.hostname === "127.0.0.1") {
    notice(
      "Testing on another phone? Open this page using your shared server address before creating its invitation.",
    );
  }
}
function connect() {
  if (stopped || !credentials) return;
  clearTimeout(retryTimer);
  clearInterval(heartbeat);
  connection(retries ? "Reconnecting…" : "Connecting…");
  const url = new URL(route("/events"), location.origin);
  url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const current = new WebSocket(url);
  socket = current;
  current.onopen = () => {
    if (current !== socket || stopped) return current.close();
    current.send(
      JSON.stringify({ type: "authenticate", token: credentials.token }),
    );
    heartbeat = setInterval(() => {
      if (current.readyState === WebSocket.OPEN) {
        current.send(JSON.stringify({ type: "ping" }));
        if (listening) activity("listening");
        else if (cameraStream) activity("signing");
      }
    }, 5000);
  };
  current.onmessage = ({ data }) => {
    if (current !== socket || stopped) return;
    const packet = JSON.parse(data);
    if (packet.type === "ended")
      return finish("The conversation ended or reached its two-hour limit.");
    if (
      packet.type !== "snapshot" ||
      (snapshot && packet.version < snapshot.version)
    )
      return;
    const previous = snapshot;
    snapshot = packet;
    retries = 0;
    connection("Connected", true);
    const other = packet.participants.find(
      (p) => p.id !== credentials.participant_id,
    );
    const me = packet.participants.find(
      (p) => p.id === credentials.participant_id,
    );
    $("chat-title").textContent = other
      ? `You & ${other.name}`
      : "You & your conversation partner";
    $("partner-status").textContent = other
      ? `${other.name} · ${other.online ? "Connected and ready" : "Reconnecting — messages will wait here"}`
      : "Waiting for the other person to join…";
    $("activity").textContent =
      other && other.activity !== "idle"
        ? `${other.name} is ${other.activity}…`
        : "";
    if (other && (!previous || previous.participants.length < 2))
      $("invite").open = false;
    if (Date.now() / 1000 > packet.join_until && !other)
      $("invite-expiry").textContent =
        "Invitation expired. Start a new conversation to invite someone.";
    if (initialSnapshot && me) setMode(me.mode);
    const committed = new Set(
      packet.messages
        .filter((m) => m.status !== "processing")
        .map((m) => `${m.sender_id}:${m.id}`),
    );
    outbox = outbox.filter(
      (p) =>
        !committed.has(`${credentials.participant_id}:${p.body.message_id}`),
    );
    packet.messages.forEach((message) => {
      const key = `${message.sender_id}:${message.id}`;
      if (message.status === "processing" || finalMessages.has(key)) return;
      finalMessages.add(key);
      if (
        !initialSnapshot &&
        message.sender_id !== credentials.participant_id &&
        message.source === "sign" &&
        message.status === "accepted" &&
        $("auto-speak").checked
      )
        speak(message.text);
    });
    outbox.forEach((item) => {
      if (item.error?.startsWith("Connection interrupted")) item.error = null;
    });
    initialSnapshot = false;
    renderMessages();
    renderOutbox();
    persist();
    flush();
  };
  current.onerror = () => {}; // onclose owns one bounded reconnect timer.
  current.onclose = async (event) => {
    if (current !== socket || stopped) return;
    clearInterval(heartbeat);
    connection("Reconnecting…");
    if (event.code === 4401) {
      try {
        await api(route());
      } catch (error) {
        if ([401, 410].includes(error.status)) return finish(error.message);
      }
    }
    try {
      await api(route());
    } catch (error) {
      if ([401, 410].includes(error.status)) return finish(error.message);
    }
    retryTimer = setTimeout(connect, Math.min(1000 * 2 ** retries++, 10000));
  };
}
function activity(state) {
  if (socket?.readyState === WebSocket.OPEN)
    socket.send(JSON.stringify({ type: "activity", state }));
}
function renderMessages() {
  if (!snapshot.messages.length) return;
  const list = $("messages");
  const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 90;
  // Keep stable message nodes so screen readers don't announce the entire history on heartbeats.
  const existing = new Map(
    [...list.querySelectorAll(".message")].map((node) => [
      node.dataset.key,
      node,
    ]),
  );
  list.querySelector(".empty")?.remove();
  for (const message of snapshot.messages) {
    const key = `${message.sender_id}:${message.id}`;
    const old = existing.get(key);
    const signature = JSON.stringify(message);
    if (old?.dataset.signature === signature) continue;
    const mine = message.sender_id === credentials.participant_id;
    const sender = snapshot.participants.find(
      (p) => p.id === message.sender_id,
    );
    const node = document.createElement("article");
    node.className = `message ${mine ? "mine" : ""} ${message.status}`;
    node.dataset.key = key;
    node.dataset.signature = signature;
    const meta = document.createElement("div");
    meta.className = "message-meta";
    meta.textContent = `${mine ? "You" : sender?.name || "Partner"} · ${message.source === "sign" ? "Signed" : message.source === "speech" ? "Spoken" : "Typed"} · ${new Date(message.created_at * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`;
    const bubble = document.createElement("div");
    bubble.className = "bubble";
    bubble.textContent =
      message.status === "processing"
        ? "Translating…"
        : message.status === "repair"
          ? mine
            ? message.prompt
            : "Clarifying a sign. Waiting for a repeat or a typed message…"
          : message.text;
    node.append(meta, bubble);
    if (message.demo && message.status === "accepted") {
      const note = document.createElement("div");
      note.className = "message-note";
      note.textContent = "Demo word preview · no sentence translation";
      node.append(note);
    }
    if (message.status === "accepted" && "speechSynthesis" in window) {
      const replay = document.createElement("button");
      replay.className = "replay";
      replay.textContent = "▷ Read aloud";
      replay.onclick = () => speak(message.text);
      node.append(replay);
    }
    if (message.status === "repair" && mine) {
      const repeat = document.createElement("button");
      repeat.className = "replay";
      repeat.textContent = "Type a correction";
      repeat.onclick = () => $("draft").focus();
      node.append(repeat);
    }
    if (old) old.replaceWith(node);
    else list.append(node);
  }
  if (atBottom) list.scrollTop = list.scrollHeight;
}
function renderOutbox() {
  $("outbox").replaceChildren();
  for (const item of outbox) {
    const node = document.createElement("div");
    node.className = "pending";
    const text = document.createElement("span");
    text.textContent = `${item.error || "Sending — waiting for confirmation"}: ${item.body.text || item.body.words.map((w) => w.word).join(" ")}`;
    const retry = document.createElement("button");
    retry.textContent = "Retry";
    retry.onclick = () => {
      item.error = null;
      persist();
      flush();
    };
    const discard = document.createElement("button");
    discard.textContent = "Dismiss";
    discard.onclick = () => {
      outbox = outbox.filter((entry) => entry !== item);
      persist();
      renderOutbox();
    };
    node.append(text, retry, discard);
    $("outbox").append(node);
  }
}
function enqueue(endpoint, body) {
  if (!credentials || stopped)
    throw new Error("Join a conversation before sending.");
  if (outbox.length >= 20)
    throw new Error(
      "Your pending messages are full. Reconnect or dismiss some messages.",
    );
  const existing = outbox.find((p) => p.body.message_id === body.message_id);
  if (existing) {
    if (JSON.stringify(existing.body) !== JSON.stringify(body))
      throw new Error("Use a new message ID for changed words.");
    return body.message_id;
  }
  outbox.push({ endpoint, body, error: null });
  persist();
  renderOutbox();
  flush();
  return body.message_id;
}
async function flush() {
  if (flushing || stopped || !snapshot || socket?.readyState !== WebSocket.OPEN)
    return;
  flushing = true;
  try {
    while (outbox.length && !stopped) {
      const item = outbox[0];
      if (item.error) break;
      try {
        await api(route(item.endpoint), "POST", item.body);
        outbox = outbox.filter((p) => p !== item);
        persist();
        renderOutbox();
      } catch (error) {
        if ([401, 410].includes(error.status)) {
          finish(error.message);
          break;
        }
        item.error = error.status
          ? error.message
          : "Connection interrupted. Retry when connected";
        persist();
        renderOutbox();
        break;
      }
    }
  } finally {
    flushing = false;
  }
}
function submitWords(input) {
  const payload = typeof input === "string" ? JSON.parse(input) : input;
  if (
    !payload ||
    typeof payload !== "object" ||
    Array.isArray(payload) ||
    Object.keys(payload).some((k) => !["words", "message_id"].includes(k))
  )
    throw new Error("Provide only words and an optional message_id.");
  if (
    !Array.isArray(payload.words) ||
    !payload.words.length ||
    payload.words.length > 64
  )
    throw new Error("Provide between 1 and 64 words.");
  const words = payload.words.map((item) => {
    if (
      !item ||
      Object.keys(item).some((k) => !["word", "confidence"].includes(k)) ||
      typeof item.word !== "string" ||
      !item.word.trim() ||
      item.word.trim().length > 80 ||
      !Number.isFinite(item.confidence) ||
      item.confidence < 0 ||
      item.confidence > 1
    )
      throw new Error(
        "Each word needs text and a confidence score between 0 and 1.",
      );
    return { word: item.word.trim(), confidence: item.confidence };
  });
  const message_id = payload.message_id || uuid();
  enqueue("/words", { message_id, words });
  return message_id;
}
// A classifier can call this after it finishes an utterance, or dispatch the event below.
window.signBridgeConversation = Object.freeze({ submitWords });
window.addEventListener("signbridge:words", ({ detail }) => {
  try {
    submitWords(detail);
  } catch (error) {
    notice(error.message);
  }
});
function setMode(mode) {
  inputMode = mode;
  $("sign-tab").setAttribute("aria-pressed", String(mode === "sign"));
  $("speech-tab").setAttribute("aria-pressed", String(mode === "speech"));
  $("sign-input").hidden = mode !== "sign";
  $("speech-input").hidden = mode !== "speech";
  if (mode === "speech") stopCamera();
  else stopRecognition();
}
function stopCamera() {
  cameraRevision++;
  cameraStream?.getTracks().forEach((track) => track.stop());
  cameraStream = null;
  $("camera").srcObject = null;
  $("camera").hidden = true;
  $("camera-placeholder").hidden = false;
  $("camera-toggle").textContent = "Open camera preview";
  activity("idle");
}
async function camera() {
  if (cameraStream) return stopCamera();
  if (cameraStarting) return;
  if (!navigator.mediaDevices?.getUserMedia)
    return notice(
      "Camera access needs HTTPS or localhost. You can still type or load words JSON.",
    );
  cameraStarting = true;
  const revision = ++cameraRevision;
  $("camera-toggle").disabled = true;
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: "user" },
      audio: false,
    });
    if (revision !== cameraRevision || stopped || inputMode !== "sign") {
      stream.getTracks().forEach((t) => t.stop());
      return;
    }
    cameraStream = stream;
    $("camera").srcObject = stream;
    $("camera").hidden = false;
    $("camera-placeholder").hidden = true;
    $("camera-toggle").textContent = "Close camera";
    activity("signing");
  } catch {
    notice(
      "Camera access was unavailable or denied. You can still type or load words JSON.",
    );
  } finally {
    cameraStarting = false;
    $("camera-toggle").disabled = false;
  }
}
function stopRecognition() {
  recognition?.abort();
  recognition = null;
  listening = false;
  $("microphone").textContent = "Start microphone";
  $("quick-speech").textContent = "Speak a message";
  $("draft").readOnly = false;
  $("send").disabled = false;
  activity("idle");
}
function microphone() {
  if (listening) {
    recognition?.stop();
    $("microphone").textContent = "Finishing…";
    return;
  }
  if (!Recognition)
    return notice(
      "Speech recognition is unavailable in this browser. Please type your message.",
    );
  window.speechSynthesis?.cancel();
  const current = new Recognition();
  recognition = current;
  current.lang = $("speech-language").value;
  current.continuous = false;
  current.interimResults = true;
  const prefix = $("draft").value.trim();
  current.onresult = (event) => {
    if (recognition !== current) return;
    const text = [...event.results].map((r) => r[0].transcript).join(" ");
    $("draft").value = `${prefix}${prefix ? " " : ""}${text}`.slice(0, 2000);
    draftSource = "speech";
    $("speech-status").textContent =
      "Listening… Your draft is visible in the message box.";
  };
  current.onend = () => {
    if (recognition !== current) return;
    recognition = null;
    listening = false;
    $("draft").readOnly = false;
    $("send").disabled = false;
    $("microphone").textContent = "Start microphone";
    $("quick-speech").textContent = "Speak a message";
    activity("idle");
    $("speech-status").textContent = "Review your message, then press Send.";
  };
  current.onerror = (event) => {
    if (recognition !== current) return;
    notice(
      event.error === "not-allowed"
        ? "Microphone permission was denied. You can type instead."
        : "Speech recognition stopped. Try again or type your message.",
    );
  };
  try {
    current.start();
    listening = true;
    $("draft").readOnly = true;
    $("send").disabled = true;
    $("microphone").textContent = "Stop microphone";
    $("quick-speech").textContent = "Stop microphone";
    $("speech-status").textContent = "Listening…";
    activity("listening");
  } catch {
    stopRecognition();
    notice("Microphone could not start. Please try again.");
  }
}
function speak(text) {
  if (!("speechSynthesis" in window)) return;
  stopRecognition();
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.lang = $("speech-language").value;
  utterance.rate = 0.95;
  utterance.onerror = () =>
    notice("Audio playback was unavailable. The message is still readable.");
  window.speechSynthesis.speak(utterance);
}
function finish(reason) {
  stopped = true;
  clearTimeout(retryTimer);
  clearInterval(heartbeat);
  stopCamera();
  stopRecognition();
  window.speechSynthesis?.cancel();
  socket?.close();
  if (credentials) {
    try {
      sessionStorage.removeItem(sessionKey(credentials.code));
    } catch {}
  }
  credentials = null;
  outbox = [];
  snapshot = null;
  $("room").hidden = true;
  $("lobby").hidden = true;
  $("ended").hidden = false;
  $("ended-reason").textContent = reason;
  $("messages").replaceChildren();
  $("outbox").replaceChildren();
  connection("Conversation ended");
  notice("");
  history.replaceState(null, "", "/conversation");
}
$("create").onclick = () => enter(false);
$("join-form").onsubmit = (event) => {
  event.preventDefault();
  enter(true);
};
$("sign-tab").onclick = () => setMode("sign");
$("speech-tab").onclick = () => setMode("speech");
$("quick-speech").onclick = () => {
  if (inputMode !== "speech") setMode("speech");
  microphone();
};
$("quick-sign").onclick = () => {
  setMode("sign");
  document
    .querySelector(".input-panel")
    .scrollIntoView({ behavior: "smooth", block: "start" });
};
$("camera-toggle").onclick = camera;
$("microphone").onclick = microphone;
$("copy").onclick = async () => {
  const link = `${location.origin}/conversation?room=${credentials.code}`;
  try {
    await navigator.clipboard.writeText(link);
    $("copy").textContent = "Link copied";
    setTimeout(() => {
      $("copy").textContent = "Copy invitation link";
    }, 2000);
  } catch {
    notice(`Copy this invitation: ${link}`);
  }
};
$("end").onclick = async () => {
  if (
    !confirm(
      "End this conversation for both people? Its room history will be cleared.",
    )
  )
    return;
  try {
    await api(route(), "DELETE");
    finish("You ended the conversation. Its room history has been cleared.");
  } catch (error) {
    if ([401, 410].includes(error.status)) finish(error.message);
    else notice("Could not end the room. Reconnect and try again.");
  }
};
$("restart").onclick = () => location.assign("/conversation");
$("compose").onsubmit = (event) => {
  event.preventDefault();
  if (listening) return;
  const text = $("draft").value.trim();
  if (!text) return;
  try {
    enqueue("/messages", { message_id: uuid(), text, source: draftSource });
    $("draft").value = "";
    draftSource = "text";
    activity("idle");
  } catch (error) {
    notice(error.message);
  }
};
$("draft").onkeydown = (event) => {
  if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    $("compose").requestSubmit();
  }
};
$("draft").oninput = () => {
  draftSource = "text";
  if (Date.now() - typingAt > 1000) {
    activity("typing");
    typingAt = Date.now();
  }
};
$("sample").onclick = () => {
  try {
    submitWords({ words: [{ word: "HELLO", confidence: 0.96 }] });
  } catch (error) {
    notice(error.message);
  }
};
$("uncertain").onclick = () => {
  try {
    submitWords({ words: [{ word: "HELP", confidence: 0.35 }] });
  } catch (error) {
    notice(error.message);
  }
};
$("send-words").onclick = () => {
  try {
    submitWords($("words-json").value);
    notice("");
  } catch (error) {
    notice(error.message);
  }
};
$("words-file").onchange = async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  try {
    if (file.size > 16384)
      throw new Error("Choose a JSON file smaller than 16 KB.");
    const text = await file.text();
    $("words-json").value = text;
    submitWords(text);
    notice("");
  } catch (error) {
    notice(error.message);
  } finally {
    event.target.value = "";
  }
};
$("auto-speak").onchange = () => {
  if (!$("auto-speak").checked) window.speechSynthesis?.cancel();
};
window.addEventListener("online", () => {
  outbox.forEach((item) => {
    if (item.error?.startsWith("Connection interrupted")) item.error = null;
  });
  if (!stopped && credentials && socket?.readyState !== WebSocket.OPEN) {
    socket?.close();
    connect();
  } else flush();
});
window.addEventListener("pagehide", () => {
  stopCamera();
  stopRecognition();
  window.speechSynthesis?.cancel();
  socket?.close();
});
window.addEventListener("pageshow", (event) => {
  if (event.persisted && credentials && !stopped) connect();
});
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    stopCamera();
    stopRecognition();
  }
});
if (!Recognition) {
  $("microphone").disabled = true;
  $("quick-speech").disabled = true;
  $("speech-status").textContent =
    "Speech recognition is unavailable here. Use the message box to type.";
}
if (!("speechSynthesis" in window)) $("auto-speak").disabled = true;
api("/healthz", "GET", undefined, false)
  .then((data) => {
    $("translation-mode").textContent =
      data.translation_mode === "demo"
        ? "Demo mode · words are shown literally. Sentence translation is not connected."
        : "Words are sent to the connected translation service.";
  })
  .catch(() => {
    $("translation-mode").textContent =
      "The translation service could not be reached.";
  });
if (invitedCode) {
  $("room-code").value = invitedCode;
  document.querySelector('input[name="mode"][value="speech"]').checked = true;
  const saved = storageRead(sessionKey(invitedCode));
  if (saved?.credentials?.code === invitedCode) {
    credentials = saved.credentials;
    outbox = saved.outbox || [];
    startRoom("sign");
  } else $("name").focus();
}
