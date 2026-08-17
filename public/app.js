const authPanel = document.querySelector("#auth-panel");
const chatPanel = document.querySelector("#chat-panel");
const tokenInput = document.querySelector("#token");
const statusElement = document.querySelector("#status");
const messagesElement = document.querySelector("#messages");
const form = document.querySelector("#chat-form");
const promptInput = document.querySelector("#prompt");
const sendButton = document.querySelector("#send");
let token = sessionStorage.getItem("webChatToken") ?? "";
const conversation = [];

function appendMessage(role, content, detail = "") {
  const article = document.createElement("article");
  article.className = `message ${role}`;
  const label = document.createElement("span");
  label.textContent = role === "user" ? "You" : "Nemotron";
  const paragraph = document.createElement("p");
  paragraph.textContent = content;
  article.append(label, paragraph);
  if (detail) {
    const metadata = document.createElement("small");
    metadata.textContent = detail;
    article.append(metadata);
  }
  messagesElement.append(article);
  messagesElement.scrollTop = messagesElement.scrollHeight;
}

function unlock(value) {
  token = value.trim();
  if (!token) {
    return;
  }
  sessionStorage.setItem("webChatToken", token);
  authPanel.hidden = true;
  chatPanel.hidden = false;
  promptInput.focus();
}

document.querySelector("#save-token").addEventListener("click", () => unlock(tokenInput.value));
tokenInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    unlock(tokenInput.value);
  }
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const prompt = promptInput.value.trim();
  if (!prompt) {
    return;
  }

  conversation.push({ role: "user", content: prompt });
  appendMessage("user", prompt);
  promptInput.value = "";
  promptInput.disabled = true;
  sendButton.disabled = true;
  statusElement.textContent = "Nemotron is responding";

  try {
    const response = await fetch("/api/chat", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ messages: conversation }),
    });
    const result = await response.json();
    if (response.status === 401) {
      sessionStorage.removeItem("webChatToken");
      authPanel.hidden = false;
      chatPanel.hidden = true;
      throw new Error("Access token rejected.");
    }
    if (!response.ok) {
      throw new Error(result.error ?? `Request failed with HTTP ${response.status}.`);
    }
    conversation.push({ role: "assistant", content: result.message });
    const detail = result.toolActivity?.length
      ? `Used read-only MCP tool in namespace: ${result.toolActivity[0].namespace}`
      : `Model: ${result.model}`;
    appendMessage("assistant", result.message, detail);
    statusElement.textContent = "Service ready";
  } catch (error) {
    appendMessage("assistant", `Request failed: ${error.message}`);
    statusElement.textContent = "Request failed";
  } finally {
    promptInput.disabled = false;
    sendButton.disabled = false;
    promptInput.focus();
  }
});

fetch("/readyz")
  .then((response) => {
    statusElement.textContent = response.ok ? "Service ready" : "Service starting";
  })
  .catch(() => {
    statusElement.textContent = "Service unavailable";
  });

if (token) {
  unlock(token);
}
