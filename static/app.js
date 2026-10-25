(() => {
  // DOM Elements
  const statusPill = document.getElementById("statusPill");
  const statusText = document.getElementById("statusText");
  const deviceBadge = document.getElementById("deviceBadge");

  const dropzone = document.getElementById("dropzone");
  const fileInput = document.getElementById("fileInput");
  const emptyState = document.getElementById("emptyState");
  const previewContainer = document.getElementById("previewContainer");
  const imagePreview = document.getElementById("imagePreview");
  const detectionCanvas = document.getElementById("detectionCanvas");
  const canvasTooltip = document.getElementById("canvasTooltip");
  const imageMeta = document.getElementById("imageMeta");

  const detCountBadge = document.getElementById("detCountBadge");
  const showBoxesToggle = document.getElementById("showBoxesToggle");
  const showNumbersToggle = document.getElementById("showNumbersToggle");
  const redetectBtn = document.getElementById("redetectBtn");

  const pasteBtn = document.getElementById("pasteBtn");
  const sampleBtn = document.getElementById("sampleBtn");
  const rotateLeftBtn = document.getElementById("rotateLeftBtn");
  const rotateRightBtn = document.getElementById("rotateRightBtn");
  const changeImageBtn = document.getElementById("changeImageBtn");
  const clearImageBtn = document.getElementById("clearImageBtn");

  const detModeSelect = document.getElementById("detModeSelect");
  const taskSelect = document.getElementById("taskSelect");
  const customPromptWrap = document.getElementById("customPromptWrap");
  const customPromptInput = document.getElementById("customPromptInput");
  const maxTokensInput = document.getElementById("maxTokensInput");
  const maxTokensVal = document.getElementById("maxTokensVal");
  const useLoraToggle = document.getElementById("useLoraToggle");
  const streamToggle = document.getElementById("streamToggle");

  const runOcrBtn = document.getElementById("runOcrBtn");
  const runOcrBtnText = document.getElementById("runOcrBtnText");
  const compareBtn = document.getElementById("compareBtn");

  const tabCombinedBtn = document.getElementById("tabCombinedBtn");
  const tabRegionsBtn = document.getElementById("tabRegionsBtn");
  const regionTabCount = document.getElementById("regionTabCount");

  const liveProgressBarWrap = document.getElementById("liveProgressBarWrap");
  const liveProgressText = document.getElementById("liveProgressText");
  const liveProgressPct = document.getElementById("liveProgressPct");
  const liveProgressFill = document.getElementById("liveProgressFill");

  const ocrOutput = document.getElementById("ocrOutput");
  const singleOutputWrap = document.getElementById("singleOutputWrap");
  const regionsInspectorWrap = document.getElementById("regionsInspectorWrap");
  const regionsList = document.getElementById("regionsList");

  const compareOutputWrap = document.getElementById("compareOutputWrap");
  const compareLoraText = document.getElementById("compareLoraText");
  const compareBaseText = document.getElementById("compareBaseText");
  const compareLoraTime = document.getElementById("compareLoraTime");
  const compareBaseTime = document.getElementById("compareBaseTime");

  const metricsBar = document.getElementById("metricsBar");
  const metricModel = document.getElementById("metricModel");
  const metricRegions = document.getElementById("metricRegions");
  const metricTime = document.getElementById("metricTime");
  const metricSpeed = document.getElementById("metricSpeed");
  const metricChars = document.getElementById("metricChars");

  const fontDecBtn = document.getElementById("fontDecBtn");
  const fontIncBtn = document.getElementById("fontIncBtn");
  const copyBtn = document.getElementById("copyBtn");
  const copyBtnText = document.getElementById("copyBtnText");
  const downloadTxtBtn = document.getElementById("downloadTxtBtn");
  const downloadDocxPlainBtn = document.getElementById("downloadDocxPlainBtn");
  const downloadMdBtn = document.getElementById("downloadMdBtn");
  const downloadJsonBtn = document.getElementById("downloadJsonBtn");

  const pageLayoutCanvas = document.getElementById("pageLayoutCanvas");
  const copyLayoutBtn = document.getElementById("copyLayoutBtn");
  const copyLayoutBtnText = document.getElementById("copyLayoutBtnText");
  const downloadLayoutTxtBtn = document.getElementById("downloadLayoutTxtBtn");
  const downloadDocxLayoutBtn = document.getElementById("downloadDocxLayoutBtn");
  const themeToggleBtn = document.getElementById("themeToggleBtn");

  const historyList = document.getElementById("historyList");
  const historyCount = document.getElementById("historyCount");
  const clearHistoryBtn = document.getElementById("clearHistoryBtn");
  const toastEl = document.getElementById("toast");

  // State
  let currentFile = null;
  let currentDataUrl = null;
  let modelReady = false;
  let isGenerating = false;
  let fontSizeRem = 1.15;
  let lastResultMeta = null;
  let scanHistory = [];
  let activeTab = "combined"; // "combined" | "regions"
  let pageLayoutMathGeneration = 0;
  let pageLayoutMathEntries = [];

  // Live Detection State
  // Each box item: { id, bbox: [x1,y1,x2,y2], polygon: [[x,y]...], status: 'pending'|'active'|'done', text?: string, thumb?: string, elapsed_ms?: number }
  let detectedBoxes = [];
  let hoveredBoxId = null;

  // Theme Toggle (Light by default like KhmerScan, with Dark Mode toggle)
  const savedTheme = localStorage.getItem("khmerocr_theme") || "light";
  document.documentElement.setAttribute("data-theme", savedTheme);
  if (themeToggleBtn) {
    themeToggleBtn.textContent = savedTheme === "dark" ? "☀️" : "🌙";
    themeToggleBtn.addEventListener("click", () => {
      const cur = document.documentElement.getAttribute("data-theme") || "light";
      const next = cur === "dark" ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", next);
      localStorage.setItem("khmerocr_theme", next);
      themeToggleBtn.textContent = next === "dark" ? "☀️" : "🌙";
    });
  }

  function showToast(msg, duration = 2600) {
    toastEl.textContent = msg;
    toastEl.hidden = false;
    clearTimeout(showToast._timer);
    showToast._timer = setTimeout(() => {
      toastEl.hidden = true;
    }, duration);
  }

  // View Tab Switching
  function switchTab(tab) {
    activeTab = tab;
    compareOutputWrap.hidden = true;
    if (tab === "combined") {
      tabCombinedBtn.classList.add("active");
      tabRegionsBtn.classList.remove("active");
      singleOutputWrap.hidden = false;
      regionsInspectorWrap.hidden = true;
    } else {
      tabCombinedBtn.classList.remove("active");
      tabRegionsBtn.classList.add("active");
      singleOutputWrap.hidden = true;
      regionsInspectorWrap.hidden = false;
    }
  }

  tabCombinedBtn.addEventListener("click", () => switchTab("combined"));
  tabRegionsBtn.addEventListener("click", () => switchTab("regions"));

  // Poll Backend Model Status
  async function checkStatus() {
    try {
      const res = await fetch("/api/status");
      const data = await res.json();

      statusPill.className = `status-pill status-${data.status === "ready" ? "ready" : data.status === "error" ? "error" : "loading"}`;
      statusText.textContent = data.status_message || data.status;

      if (data.device_name) {
        deviceBadge.textContent = `${data.device_name} • ${data.dtype.toUpperCase()}`;
        deviceBadge.hidden = false;
      }

      modelReady = data.status === "ready";
      updateActionButtons();

      if (data.status !== "ready" && data.status !== "error") {
        setTimeout(checkStatus, 2000);
      }
    } catch {
      statusPill.className = "status-pill status-error";
      statusText.textContent = "Backend unreachable";
      setTimeout(checkStatus, 4000);
    }
  }

  function updateActionButtons() {
    const canRun = modelReady && currentFile && !isGenerating;
    runOcrBtn.disabled = !canRun;
    compareBtn.disabled = !canRun;

    if (!isGenerating) {
      if (!modelReady) {
        runOcrBtnText.textContent = statusText.textContent || "Loading Model...";
      } else {
        runOcrBtnText.textContent = "Extract Text (OCR)";
      }
    }

    const hasText = ocrOutput.value.trim().length > 0;
    copyBtn.disabled = !hasText;
    downloadTxtBtn.disabled = !hasText;
    if (downloadDocxPlainBtn) downloadDocxPlainBtn.disabled = !hasText;
    downloadMdBtn.disabled = !hasText;
    downloadJsonBtn.disabled = !hasText;
    if (copyLayoutBtn) copyLayoutBtn.disabled = !hasText;
    if (downloadLayoutTxtBtn) downloadLayoutTxtBtn.disabled = !hasText;
    if (downloadDocxLayoutBtn) downloadDocxLayoutBtn.disabled = !hasText;
  }

  function fitPageLayoutItem(el, availableHeightPx, preferredFontPx) {
    const minReadableFontPx = 9;
    const minFontPx = Math.min(minReadableFontPx, preferredFontPx);
    const maxHeightPx = Math.max(1, availableHeightPx);
    const setFontSize = (size) => {
      el.style.fontSize = `${size.toFixed(2)}px`;
      return el.getBoundingClientRect().height <= maxHeightPx + 0.5;
    };

    if (setFontSize(preferredFontPx)) return;
    if (!setFontSize(minFontPx)) return;

    // Keep the largest font that fits the source region after the browser wraps it.
    let fittingFontPx = minFontPx;
    let overflowingFontPx = preferredFontPx;
    for (let attempt = 0; attempt < 7; attempt += 1) {
      const candidatePx = (fittingFontPx + overflowingFontPx) / 2;
      if (setFontSize(candidatePx)) {
        fittingFontPx = candidatePx;
      } else {
        overflowingFontPx = candidatePx;
      }
    }
    el.style.fontSize = `${fittingFontPx.toFixed(2)}px`;
  }

  const TEX_MATH_DELIMITER_PATTERN = /\\\([\s\S]*?\\\)|\\\[[\s\S]*?\\\]|\$\$[\s\S]*?\$\$/;
  const TEX_DISPLAY_ENVIRONMENT_PATTERN = /\\begin\{(?:equation|align|gather|multline|flalign|alignat|displaymath)\*?\}/;
  const TEX_NESTED_MATH_ENVIRONMENT_PATTERN = /\\begin\{(?:aligned|alignedat|gathered|cases|dcases|rcases|matrix|pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix|smallmatrix|array)\}/;

  function isMathLayoutBox(box) {
    const text = String(box.text || "");
    if (TEX_MATH_DELIMITER_PATTERN.test(text) ||
        TEX_DISPLAY_ENVIRONMENT_PATTERN.test(text) ||
        TEX_NESTED_MATH_ENVIRONMENT_PATTERN.test(text)) return true;

    const label = String(box.label || "").toLowerCase().replace(/[^a-z0-9]+/g, "_");
    return /(?:^|_)(?:formula|equation|math)(?:_|$)/.test(label);
  }

  function clearMathJaxNodes(nodes) {
    const mathJax = window.MathJax;
    if (!mathJax || typeof mathJax.typesetClear !== "function" || nodes.length === 0) return;
    try {
      mathJax.typesetClear(nodes);
    } catch {
      // MathJax may still be starting up or may have failed to load.
    }
  }

  function beginPageLayoutRender() {
    pageLayoutMathGeneration += 1;
    clearMathJaxNodes([pageLayoutCanvas]);
    pageLayoutMathEntries = [];
    return pageLayoutMathGeneration;
  }

  function mathJaxInputFor(entry) {
    const rawText = String(entry.box.text || "");
    return TEX_MATH_DELIMITER_PATTERN.test(rawText) || TEX_DISPLAY_ENVIRONMENT_PATTERN.test(rawText)
      ? rawText
      : `\\[${rawText}\\]`;
  }

  function isCurrentMathEntry(entry, generation, requestId) {
    return generation === pageLayoutMathGeneration &&
      requestId === entry.typesetRequest &&
      entry.preview.isConnected &&
      !entry.preview.hidden;
  }

  function restoreRawMathPreview(entry) {
    clearMathJaxNodes([entry.preview]);
    entry.preview.textContent = String(entry.box.text || "");
    fitPageLayoutItem(entry.item, entry.regionHeightPx, entry.preferredFontPx);
  }

  function typesetMathEntry(entry, generation) {
    const requestId = ++entry.typesetRequest;
    const previous = entry.typesetPromise || Promise.resolve();
    const task = Promise.resolve(previous).catch(() => {}).then(async () => {
      if (!isCurrentMathEntry(entry, generation, requestId)) {
        clearMathJaxNodes([entry.preview]);
        return;
      }

      let mathJax = window.MathJax;
      if (mathJax?.startup?.promise) {
        try {
          await mathJax.startup.promise;
        } catch {
          // Keep the source preview if MathJax did not finish starting.
        }
      }
      if (!isCurrentMathEntry(entry, generation, requestId)) {
        clearMathJaxNodes([entry.preview]);
        return;
      }

      mathJax = window.MathJax;
      if (!mathJax || typeof mathJax.typesetPromise !== "function") {
        restoreRawMathPreview(entry);
        return;
      }

      clearMathJaxNodes([entry.preview]);
      entry.preview.textContent = mathJaxInputFor(entry);
      try {
        await mathJax.typesetPromise([entry.preview]);
      } catch {
        if (isCurrentMathEntry(entry, generation, requestId)) {
          restoreRawMathPreview(entry);
        } else {
          clearMathJaxNodes([entry.preview]);
        }
        return;
      }

      if (!isCurrentMathEntry(entry, generation, requestId)) {
        clearMathJaxNodes([entry.preview]);
        return;
      }

      if (entry.preview.querySelector("mjx-merror")) {
        restoreRawMathPreview(entry);
        return;
      }
      fitPageLayoutItem(entry.item, entry.regionHeightPx, entry.preferredFontPx);
    }).catch(() => {
      if (isCurrentMathEntry(entry, generation, requestId)) {
        restoreRawMathPreview(entry);
      } else {
        clearMathJaxNodes([entry.preview]);
      }
    });
    entry.typesetPromise = task;
    return task;
  }

  function typesetPageLayoutMath(entries, generation) {
    entries.forEach((entry) => typesetMathEntry(entry, generation));
  }

  function makeMathLayoutEntry(box, item, regionHeightPx, preferredFontPx, generation) {
    const preview = document.createElement("div");
    preview.className = "page-layout-math-preview";
    preview.textContent = String(box.text || "");

    const sourceEditor = document.createElement("textarea");
    sourceEditor.className = "page-layout-source-editor";
    sourceEditor.value = String(box.text || "");
    sourceEditor.spellcheck = false;
    sourceEditor.hidden = true;
    sourceEditor.setAttribute("aria-label", `Edit LaTeX source for region ${box.id}`);

    const sourceToggle = document.createElement("button");
    sourceToggle.type = "button";
    sourceToggle.className = "page-layout-math-toggle";
    sourceToggle.textContent = "Edit source";
    sourceToggle.setAttribute("aria-label", `Edit LaTeX source for region ${box.id}`);
    sourceToggle.title = "Edit LaTeX source";

    const entry = {
      box,
      item,
      preview,
      sourceEditor,
      regionHeightPx,
      preferredFontPx,
      typesetRequest: 0,
      typesetPromise: Promise.resolve()
    };

    sourceEditor.addEventListener("input", () => {
      box.text = sourceEditor.value;
    });
    sourceToggle.addEventListener("click", (event) => {
      event.stopPropagation();
      if (sourceEditor.hidden) {
        entry.typesetRequest += 1;
        clearMathJaxNodes([preview]);
        sourceEditor.value = String(box.text || "");
        preview.hidden = true;
        sourceEditor.hidden = false;
        item.classList.add("is-source-editing");
        sourceToggle.textContent = "Preview";
        sourceToggle.setAttribute("aria-label", `Preview region ${box.id}`);
        sourceToggle.title = "Return to rendered preview";
        sourceEditor.focus();
        return;
      }

      box.text = sourceEditor.value;
      sourceEditor.hidden = true;
      preview.hidden = false;
      item.classList.remove("is-source-editing");
      sourceToggle.textContent = "Edit source";
      sourceToggle.setAttribute("aria-label", `Edit LaTeX source for region ${box.id}`);
      sourceToggle.title = "Edit LaTeX source";
      typesetMathEntry(entry, generation);
    });

    item.append(sourceToggle, preview, sourceEditor);
    return entry;
  }

  const mathJaxScript = document.getElementById("mathJaxScript");
  if (mathJaxScript) {
    mathJaxScript.addEventListener("load", () => {
      typesetPageLayoutMath(pageLayoutMathEntries, pageLayoutMathGeneration);
    });
  }

  // Render 2D Spatial Page Layout Reconstruction (KhmerScan Bottom Card)
  function renderPageLayout() {
    if (!pageLayoutCanvas) return;
    const generation = beginPageLayoutRender();
    const doneBoxes = detectedBoxes.filter((b) => b.text && b.text.trim().length > 0);
    if (doneBoxes.length === 0) {
      pageLayoutCanvas.style.aspectRatio = "auto";
      pageLayoutCanvas.style.minHeight = "260px";
      pageLayoutCanvas.innerHTML = `
        <div class="page-layout-empty">
          ទម្រង់រៀបចំទំព័រដូចរូបភាពដើមនឹងបង្ហាញនៅទីនេះដោយស្វ័យប្រវត្តិ...<br/>
          <span>Exact 2D spatial page layout (titles, columns, stanzas, tables) will reconstruct here live as regions are recognized.</span>
        </div>
      `;
      return;
    }

    const natW = imagePreview.naturalWidth || (lastResultMeta?.image_size?.width) || 1000;
    const natH = imagePreview.naturalHeight || (lastResultMeta?.image_size?.height) || 1000;
    pageLayoutCanvas.style.aspectRatio = `${natW} / ${natH}`;
    const sheetW = pageLayoutCanvas.clientWidth || 840;
    const sheetH = Math.max(320, Math.round(sheetW * (natH / natW)));
    pageLayoutCanvas.style.minHeight = `${sheetH}px`;
    pageLayoutCanvas.innerHTML = "";

    // If single full-image box, render nicely padded document flow
    if (doneBoxes.length === 1 && doneBoxes[0].label === "full_image") {
      const item = document.createElement("div");
      item.className = "page-layout-item";
      item.style.position = "relative";
      item.style.padding = "24px";
      item.style.fontSize = "1.05rem";
      item.spellcheck = false;
      const hasMath = isMathLayoutBox(doneBoxes[0]);
      if (hasMath) {
        item.classList.add("has-math");
        item.contentEditable = "false";
      } else {
        item.contentEditable = "true";
        item.textContent = doneBoxes[0].text;
      }
      pageLayoutCanvas.appendChild(item);
      const preferredFontPx = parseFloat(getComputedStyle(item).fontSize) || 16;
      if (hasMath) {
        const entry = makeMathLayoutEntry(doneBoxes[0], item, sheetH, preferredFontPx, generation);
        pageLayoutMathEntries = [entry];
        typesetPageLayoutMath(pageLayoutMathEntries, generation);
      } else {
        item.addEventListener("input", () => fitPageLayoutItem(item, sheetH, preferredFontPx));
        fitPageLayoutItem(item, sheetH, preferredFontPx);
      }
      return;
    }

    const mathEntries = [];
    doneBoxes.forEach((box) => {
      const [x1, y1, x2, y2] = box.bbox;
      const bw = Math.max(10, x2 - x1);
      const bh = Math.max(10, y2 - y1);
      const leftPct = Math.max(0.5, Math.min(96, (x1 / natW) * 100));
      const topPct = Math.max(0.5, Math.min(96, (y1 / natH) * 100));
      const widthPct = Math.min(99 - leftPct, (bw / natW) * 100);

      const lineCount = Math.max(1, (box.text || "").split("\n").length);
      const singleLineH = (bh / lineCount / natH) * sheetH;
      const isHeading = ["doc_title", "paragraph_title", "title"].includes(box.label);
      const computedPx = Math.max(11, Math.min(28, Math.round(singleLineH * (isHeading ? 0.56 : 0.50))));
      const regionHeightPx = (bh / natH) * sheetH;

      const el = document.createElement("div");
      el.className = `page-layout-item${isHeading ? " is-heading" : ""}`;
      el.dataset.boxId = String(box.id);
      const hasMath = isMathLayoutBox(box);
      if (hasMath) {
        el.classList.add("has-math");
        el.contentEditable = "false";
      } else {
        el.contentEditable = "true";
      }
      el.spellcheck = false;
      el.style.left = `${leftPct.toFixed(2)}%`;
      el.style.top = `${topPct.toFixed(2)}%`;
      el.style.width = `${widthPct.toFixed(2)}%`;
      el.style.fontSize = `${computedPx}px`;

      // Center-align if the box is a centered title/header on the page
      const cx = (x1 + x2) / 2;
      if (Math.abs(cx - natW / 2) < natW * 0.12 && x1 > natW * 0.08 && bw < natW * 0.86 && lineCount <= 2) {
        el.style.textAlign = "center";
      }

      if (hasMath) {
        mathEntries.push(makeMathLayoutEntry(box, el, regionHeightPx, computedPx, generation));
      } else {
        el.textContent = box.text;
      }

      el.addEventListener("mouseenter", () => {
        hoveredBoxId = box.id;
        renderDetectionOverlay();
        highlightRegionCard(box.id);
      });
      el.addEventListener("mouseleave", () => {
        hoveredBoxId = null;
        renderDetectionOverlay();
        highlightRegionCard(null);
      });
      if (!hasMath) {
        el.addEventListener("input", () => {
          box.text = el.innerText;
          fitPageLayoutItem(el, regionHeightPx, computedPx);
        });
      }

      pageLayoutCanvas.appendChild(el);
      if (!hasMath) fitPageLayoutItem(el, regionHeightPx, computedPx);
    });
    pageLayoutMathEntries = mathEntries;
    typesetPageLayoutMath(mathEntries, generation);
  }

  window.addEventListener("resize", () => {
    if (detectedBoxes.some((b) => b.text)) {
      renderPageLayout();
    }
  });

  // Draw Live Detection Overlay on <canvas id="detectionCanvas">
  function renderDetectionOverlay() {
    const ctx = detectionCanvas.getContext("2d");
    const natW = imagePreview.naturalWidth || 1;
    const natH = imagePreview.naturalHeight || 1;

    detectionCanvas.width = natW;
    detectionCanvas.height = natH;
    ctx.clearRect(0, 0, natW, natH);

    if (!showBoxesToggle.checked || detectedBoxes.length === 0) {
      return;
    }

    const scaleFactor = Math.max(1, Math.min(natW, natH) / 500);
    const showIds = showNumbersToggle.checked;

    detectedBoxes.forEach((box) => {
      const [x1, y1, x2, y2] = box.bbox;
      const bw = x2 - x1;
      const bh = y2 - y1;
      const isHovered = box.id === hoveredBoxId;

      let strokeColor = "#38bdf8"; // Pending: Cyan/Blue
      let fillColor = "rgba(56, 189, 248, 0.10)";
      let lineWidth = 2 * scaleFactor;

      if (box.status === "active") {
        strokeColor = "#f59e0b"; // Recognizing: Amber
        fillColor = "rgba(245, 158, 11, 0.26)";
        lineWidth = 3 * scaleFactor;
      } else if (box.status === "done") {
        strokeColor = "#10b981"; // Done: Emerald Green
        fillColor = isHovered ? "rgba(16, 185, 129, 0.30)" : "rgba(16, 185, 129, 0.12)";
        lineWidth = (isHovered ? 3 : 2) * scaleFactor;
      } else if (isHovered) {
        fillColor = "rgba(56, 189, 248, 0.25)";
        lineWidth = 2.8 * scaleFactor;
      }

      ctx.save();
      ctx.fillStyle = fillColor;
      ctx.strokeStyle = strokeColor;
      ctx.lineWidth = lineWidth;

      ctx.fillRect(x1, y1, bw, bh);
      ctx.strokeRect(x1, y1, bw, bh);

      if (showIds) {
        const fontSize = Math.max(11, Math.round(12 * scaleFactor));
        ctx.font = `700 ${fontSize}px Inter, sans-serif`;
        const tag = box.label && box.label !== "text_line" && box.label !== "full_image"
          ? `#${box.id} ${box.label}`
          : `#${box.id}`;
        const textWidth = ctx.measureText(tag).width;
        const padX = 4 * scaleFactor;
        const badgeH = fontSize + 4 * scaleFactor;
        const badgeY = Math.max(0, y1 - badgeH);

        ctx.fillStyle = strokeColor;
        ctx.fillRect(x1, badgeY, textWidth + padX * 2, badgeH);
        ctx.fillStyle = "#08101d";
        ctx.fillText(tag, x1 + padX, badgeY + fontSize - 1 * scaleFactor);
      }
      ctx.restore();
    });
  }

  // Run Instant Detection Preview (/api/detect)
  async function runDetectionPreview() {
    if (!currentFile) return;
    detCountBadge.textContent = "Detecting text boxes...";

    const fd = new FormData();
    fd.append("file", currentFile);
    fd.append("det_mode", detModeSelect.value);

    try {
      const res = await fetch("/api/detect", { method: "POST", body: fd });
      if (!res.ok) return;
      const data = await res.json();
      detectedBoxes = (data.boxes || []).map((b) => ({
        ...b,
        status: "pending",
        text: "",
      }));
      detCountBadge.textContent = `${detectedBoxes.length} region${detectedBoxes.length === 1 ? "" : "s"} detected (${data.elapsed_ms}ms)`;
      regionTabCount.textContent = String(detectedBoxes.length);
      renderDetectionOverlay();
    } catch {
      detCountBadge.textContent = "Detection ready";
    }
  }

  // Canvas Mouse Hover & Click Interaction
  detectionCanvas.addEventListener("mousemove", (e) => {
    if (detectedBoxes.length === 0) return;
    const rect = detectionCanvas.getBoundingClientRect();
    const scaleX = detectionCanvas.width / rect.width;
    const scaleY = detectionCanvas.height / rect.height;
    const mx = (e.clientX - rect.left) * scaleX;
    const my = (e.clientY - rect.top) * scaleY;

    const hit = detectedBoxes.find((b) => {
      const [x1, y1, x2, y2] = b.bbox;
      return mx >= x1 && mx <= x2 && my >= y1 && my <= y2;
    });

    const newHoverId = hit ? hit.id : null;
    if (newHoverId !== hoveredBoxId) {
      hoveredBoxId = newHoverId;
      renderDetectionOverlay();
      highlightRegionCard(hoveredBoxId);
    }

    if (hit && hit.text) {
      canvasTooltip.textContent = `#${hit.id}: ${hit.text}`;
      canvasTooltip.style.left = `${Math.min(rect.width - 180, Math.max(8, e.clientX - rect.left + 10))}px`;
      canvasTooltip.style.top = `${Math.max(8, e.clientY - rect.top - 36)}px`;
      canvasTooltip.hidden = false;
    } else {
      canvasTooltip.hidden = true;
    }
  });

  detectionCanvas.addEventListener("mouseleave", () => {
    hoveredBoxId = null;
    canvasTooltip.hidden = true;
    renderDetectionOverlay();
    highlightRegionCard(null);
  });

  detectionCanvas.addEventListener("click", () => {
    if (hoveredBoxId) {
      switchTab("regions");
      const card = document.querySelector(`.region-card[data-box-id="${hoveredBoxId}"]`);
      if (card) card.scrollIntoView({ behavior: "smooth", block: "nearest" });
    }
  });

  function highlightRegionCard(boxId) {
    document.querySelectorAll(".region-card, .page-layout-item").forEach((el) => {
      el.classList.toggle("highlighted", Number(el.dataset.boxId) === boxId);
    });
  }

  showBoxesToggle.addEventListener("change", renderDetectionOverlay);
  showNumbersToggle.addEventListener("change", renderDetectionOverlay);
  detModeSelect.addEventListener("change", () => {
    if (currentFile && !isGenerating) runDetectionPreview();
  });
  redetectBtn.addEventListener("click", () => {
    if (currentFile && !isGenerating) runDetectionPreview();
  });

  // Load Image File into Preview & Immediately Detect Boxes
  function loadImageFile(file) {
    if (!file || !file.type.startsWith("image/")) {
      showToast("Please select a valid image file.");
      return;
    }
    currentFile = file;
    detectedBoxes = [];
    const reader = new FileReader();
    reader.onload = (e) => {
      currentDataUrl = e.target.result;
      imagePreview.onload = () => {
        const kb = Math.round(file.size / 1024);
        imageMeta.textContent = `${imagePreview.naturalWidth} × ${imagePreview.naturalHeight} px • ${kb} KB`;
        renderDetectionOverlay();
        runDetectionPreview();
      };
      imagePreview.src = currentDataUrl;
      emptyState.hidden = true;
      previewContainer.hidden = false;
      updateActionButtons();
    };
    reader.readAsDataURL(file);
  }

  // Rotate current image 90 degrees via Canvas
  function rotateCurrentImage(degrees) {
    if (!currentDataUrl) return;
    const img = new Image();
    img.onload = () => {
      const canvas = document.createElement("canvas");
      const swap = Math.abs(degrees) === 90;
      canvas.width = swap ? img.height : img.width;
      canvas.height = swap ? img.width : img.height;
      const ctx = canvas.getContext("2d");
      ctx.translate(canvas.width / 2, canvas.height / 2);
      ctx.rotate((degrees * Math.PI) / 180);
      ctx.drawImage(img, -img.width / 2, -img.height / 2);
      canvas.toBlob((blob) => {
        if (blob) {
          const rotatedFile = new File([blob], currentFile?.name || "rotated.png", { type: "image/png" });
          loadImageFile(rotatedFile);
        }
      }, "image/png");
    };
    img.src = currentDataUrl;
  }

  // Generate a synthetic Khmer Sample Image for instant testing
  function generateKhmerSample() {
    const canvas = document.createElement("canvas");
    canvas.width = 920;
    canvas.height = 280;
    const ctx = canvas.getContext("2d");

    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    ctx.strokeStyle = "#e2e8f0";
    ctx.lineWidth = 2;
    ctx.strokeRect(12, 12, canvas.width - 24, canvas.height - 24);

    ctx.fillStyle = "#0f172a";
    ctx.font = "600 32px 'Kantumruy Pro', 'Noto Sans Khmer', sans-serif";
    ctx.fillText("ព្រះរាជាណាចក្រកម្ពុជា", 40, 72);

    ctx.font = "400 25px 'Kantumruy Pro', 'Noto Sans Khmer', sans-serif";
    ctx.fillText("ជាតិ សាសនា ព្រះមហាក្សត្រ", 40, 125);
    ctx.fillText("ការអភិវឌ្ឍបច្ចេកវិទ្យាបញ្ញាសិប្បនិម្មិតសម្រាប់ភាសាខ្មែរ", 40, 180);

    ctx.fillStyle = "#334155";
    ctx.font = "400 20px 'Inter', sans-serif";
    ctx.fillText("Khmer PaddleOCR-VL Fine-Tuned LoRA • ២០២៦", 40, 232);

    canvas.toBlob((blob) => {
      if (blob) {
        const file = new File([blob], "khmer_sample.png", { type: "image/png" });
        loadImageFile(file);
        showToast("Loaded Khmer sample image!");
      }
    }, "image/png");
  }

  // Upload / Drag & Drop / Paste Listeners
  emptyState.addEventListener("click", () => fileInput.click());
  emptyState.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    event.preventDefault();
    fileInput.click();
  });
  changeImageBtn.addEventListener("click", () => fileInput.click());

  clearImageBtn.addEventListener("click", () => {
    currentFile = null;
    currentDataUrl = null;
    detectedBoxes = [];
    fileInput.value = "";
    previewContainer.hidden = true;
    emptyState.hidden = false;
    updateActionButtons();
  });

  fileInput.addEventListener("change", (e) => {
    if (e.target.files && e.target.files[0]) {
      loadImageFile(e.target.files[0]);
    }
  });

  dropzone.addEventListener("dragover", (e) => {
    e.preventDefault();
    dropzone.classList.add("dragover");
  });

  dropzone.addEventListener("dragleave", () => {
    dropzone.classList.remove("dragover");
  });

  dropzone.addEventListener("drop", (e) => {
    e.preventDefault();
    dropzone.classList.remove("dragover");
    if (e.dataTransfer.files && e.dataTransfer.files[0]) {
      loadImageFile(e.dataTransfer.files[0]);
    }
  });

  window.addEventListener("paste", (e) => {
    if (!e.clipboardData) return;
    const items = e.clipboardData.items;
    for (let i = 0; i < items.length; i++) {
      if (items[i].type.startsWith("image/")) {
        const file = items[i].getAsFile();
        if (file) {
          loadImageFile(file);
          showToast("Image pasted from clipboard!");
          e.preventDefault();
          return;
        }
      }
    }
  });

  pasteBtn.addEventListener("click", async () => {
    try {
      const clipboardItems = await navigator.clipboard.read();
      for (const item of clipboardItems) {
        const imageType = item.types.find((t) => t.startsWith("image/"));
        if (imageType) {
          const blob = await item.getType(imageType);
          loadImageFile(new File([blob], "clipboard.png", { type: imageType }));
          showToast("Image pasted from clipboard!");
          return;
        }
      }
      showToast("No image found in clipboard. Copy an image first or press Ctrl+V.");
    } catch {
      showToast("Press Ctrl+V anywhere on the page to paste an image.");
    }
  });

  sampleBtn.addEventListener("click", generateKhmerSample);
  rotateLeftBtn.addEventListener("click", () => rotateCurrentImage(-90));
  rotateRightBtn.addEventListener("click", () => rotateCurrentImage(90));

  taskSelect.addEventListener("change", () => {
    customPromptWrap.hidden = taskSelect.value !== "custom";
  });

  maxTokensInput.addEventListener("input", () => {
    maxTokensVal.textContent = maxTokensInput.value;
  });

  ocrOutput.addEventListener("input", () => {
    metricChars.textContent = `${ocrOutput.value.length} chars`;
    updateActionButtons();
  });

  fontDecBtn.addEventListener("click", () => {
    fontSizeRem = Math.max(0.85, +(fontSizeRem - 0.1).toFixed(2));
    ocrOutput.style.fontSize = `${fontSizeRem}rem`;
    compareLoraText.style.fontSize = `${fontSizeRem}rem`;
    compareBaseText.style.fontSize = `${fontSizeRem}rem`;
  });

  fontIncBtn.addEventListener("click", () => {
    fontSizeRem = Math.min(2.2, +(fontSizeRem + 0.1).toFixed(2));
    ocrOutput.style.fontSize = `${fontSizeRem}rem`;
    compareLoraText.style.fontSize = `${fontSizeRem}rem`;
    compareBaseText.style.fontSize = `${fontSizeRem}rem`;
  });

  function buildFormData(useLoraOverride = null) {
    const fd = new FormData();
    fd.append("file", currentFile);
    fd.append("task", taskSelect.value);
    if (taskSelect.value === "custom") {
      fd.append("custom_prompt", customPromptInput.value);
    }
    fd.append("max_new_tokens", maxTokensInput.value);
    const useLora = useLoraOverride !== null ? useLoraOverride : useLoraToggle.checked;
    fd.append("use_lora", useLora ? "true" : "false");
    fd.append("det_mode", detModeSelect.value);
    return fd;
  }

  function updateMetrics(meta) {
    lastResultMeta = meta;
    metricsBar.hidden = false;
    metricModel.textContent = meta.use_lora ? "LoRA: Khmer-PaddleOCR-VL" : "Base: PaddleOCR-VL";
    const regCount = meta.regions ? meta.regions.length : detectedBoxes.length;
    metricRegions.textContent = `${regCount} region${regCount === 1 ? "" : "s"}`;
    metricTime.textContent = `${(meta.elapsed_ms / 1000).toFixed(2)}s`;
    metricSpeed.textContent = `${meta.tokens_per_sec} tok/s (${meta.tokens} tok)`;
    metricChars.textContent = `${(meta.text || "").length} chars`;
  }

  function upsertRegionCard(regionItem, status = "done") {
    let card = regionsList.querySelector(`.region-card[data-box-id="${regionItem.id}"]`);
    if (!card) {
      const emptyEl = regionsList.querySelector(".history-empty");
      if (emptyEl) emptyEl.remove();
      card = document.createElement("div");
      card.className = "region-card";
      card.dataset.boxId = String(regionItem.id);
      card.addEventListener("mouseenter", () => {
        hoveredBoxId = regionItem.id;
        renderDetectionOverlay();
      });
      card.addEventListener("mouseleave", () => {
        hoveredBoxId = null;
        renderDetectionOverlay();
      });
      regionsList.appendChild(card);
    }

    card.classList.toggle("active-recognizing", status === "active");
    const thumbHtml = regionItem.thumb
      ? `<img class="region-crop-thumb" src="${regionItem.thumb}" alt="Region #${regionItem.id}" />`
      : `<div class="region-crop-thumb"></div>`;

    const labelBadge = regionItem.label && regionItem.label !== "text_line"
      ? `<div class="region-label">${escapeHtml(regionItem.label)}</div>`
      : "";

    card.innerHTML = `
      <span class="region-idx">#${regionItem.id}${labelBadge}</span>
      ${thumbHtml}
      <div class="region-text">${status === "active" ? "<em>កំពុងអានអក្សរ... (Recognizing...)</em>" : escapeHtml(regionItem.text || "—")}</div>
      <span class="region-time">${regionItem.elapsed_ms ? `${(regionItem.elapsed_ms / 1000).toFixed(2)}s` : ""}</span>
    `;
  }

  // Run Single OCR with Live Region Visualization
  async function runSingleOcr() {
    if (!currentFile || isGenerating) return;

    switchTab(activeTab);
    isGenerating = true;
    runOcrBtnText.textContent = "Detecting & Recognizing...";
    ocrOutput.value = "";
    regionsList.innerHTML = "";
    liveProgressBarWrap.hidden = false;
    liveProgressText.textContent = "Detecting text regions...";
    liveProgressPct.textContent = "0%";
    liveProgressFill.style.width = "0%";
    updateActionButtons();

    const useStreaming = streamToggle.checked;
    const fd = buildFormData();

    try {
      if (useStreaming) {
        const response = await fetch("/api/ocr/stream", {
          method: "POST",
          body: fd,
        });

        if (!response.ok) {
          const err = await response.json().catch(() => ({ detail: response.statusText }));
          throw new Error(err.detail || "OCR request failed");
        }

        const reader = response.body.getReader();
        const decoder = new TextDecoder("utf-8");
        let buffer = "";

        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });

          const parts = buffer.split("\n\n");
          buffer = parts.pop() || "";

          for (const part of parts) {
            const line = part.trim();
            if (!line.startsWith("data:")) continue;
            const jsonStr = line.slice(5).trim();
            if (!jsonStr) continue;
            const event = JSON.parse(jsonStr);

            if (event.type === "detections") {
              detectedBoxes = (event.boxes || []).map((b) => ({
                ...b,
                status: "pending",
                text: "",
              }));
              detCountBadge.textContent = `${detectedBoxes.length} regions detected (${event.det_elapsed_ms}ms)`;
              regionTabCount.textContent = String(detectedBoxes.length);
              renderDetectionOverlay();
            } else if (event.type === "region_start") {
              const b = detectedBoxes.find((x) => x.id === event.box.id);
              if (b) b.status = "active";
              renderDetectionOverlay();

              const pct = Math.round(((event.index - 1) / Math.max(1, event.total)) * 100);
              liveProgressText.textContent = `Recognizing region #${event.index} of ${event.total}...`;
              liveProgressPct.textContent = `${pct}%`;
              liveProgressFill.style.width = `${pct}%`;

              upsertRegionCard({ id: event.box.id, thumb: event.thumb, text: "" }, "active");
            } else if (event.type === "region_done") {
              const reg = event.region;
              const b = detectedBoxes.find((x) => x.id === reg.id);
              if (b) {
                b.status = "done";
                b.text = reg.text;
              }
              renderDetectionOverlay();
              upsertRegionCard(reg, "done");
              renderPageLayout();

              const pct = Math.round((event.index / Math.max(1, event.total)) * 100);
              liveProgressPct.textContent = `${pct}%`;
              liveProgressFill.style.width = `${pct}%`;

              if (reg.text && event.total > 1) {
                const sep = reg.same_row_as_prev ? "    " : "\n";
                ocrOutput.value += (ocrOutput.value ? sep : "") + reg.text;
                ocrOutput.scrollTop = ocrOutput.scrollHeight;
              }
            } else if (event.type === "token") {
              ocrOutput.value += event.text;
              ocrOutput.scrollTop = ocrOutput.scrollHeight;
            } else if (event.type === "done") {
              ocrOutput.value = event.text;
              liveProgressText.textContent = `Completed ${detectedBoxes.length} regions!`;
              liveProgressPct.textContent = "100%";
              liveProgressFill.style.width = "100%";
              updateMetrics(event);
              renderPageLayout();
              addToHistory(event.text, event);
            } else if (event.type === "error") {
              throw new Error(event.error);
            }
          }
        }
      } else {
        const response = await fetch("/api/ocr", {
          method: "POST",
          body: fd,
        });
        if (!response.ok) {
          const err = await response.json().catch(() => ({ detail: response.statusText }));
          throw new Error(err.detail || "OCR request failed");
        }
        const result = await response.json();
        ocrOutput.value = result.text;
        if (result.regions) {
          detectedBoxes = result.regions.map((r) => ({ ...r, status: "done" }));
          regionTabCount.textContent = String(result.regions.length);
          result.regions.forEach((r) => upsertRegionCard(r, "done"));
          renderDetectionOverlay();
          renderPageLayout();
        }
        updateMetrics(result);
        addToHistory(result.text, result);
      }
    } catch (err) {
      showToast(`Error: ${err.message}`, 4000);
    } finally {
      isGenerating = false;
      setTimeout(() => {
        liveProgressBarWrap.hidden = true;
      }, 1200);
      updateActionButtons();
    }
  }

  // Compare Fine-Tuned LoRA vs Base Model
  async function runComparison() {
    if (!currentFile || isGenerating) return;

    singleOutputWrap.hidden = true;
    regionsInspectorWrap.hidden = true;
    compareOutputWrap.hidden = false;
    isGenerating = true;
    compareLoraText.value = "Running Fine-Tuned LoRA...";
    compareBaseText.value = "Waiting...";
    compareLoraTime.textContent = "...";
    compareBaseTime.textContent = "...";
    updateActionButtons();

    try {
      const resLora = await fetch("/api/ocr", {
        method: "POST",
        body: buildFormData(true),
      });
      if (!resLora.ok) throw new Error("LoRA inference failed");
      const dataLora = await resLora.json();
      compareLoraText.value = dataLora.text;
      compareLoraTime.textContent = `${(dataLora.elapsed_ms / 1000).toFixed(2)}s • ${dataLora.tokens_per_sec} tok/s`;

      compareBaseText.value = "Running Base PaddleOCR-VL...";
      const resBase = await fetch("/api/ocr", {
        method: "POST",
        body: buildFormData(false),
      });
      if (!resBase.ok) throw new Error("Base model inference failed");
      const dataBase = await resBase.json();
      compareBaseText.value = dataBase.text;
      compareBaseTime.textContent = `${(dataBase.elapsed_ms / 1000).toFixed(2)}s • ${dataBase.tokens_per_sec} tok/s`;

      ocrOutput.value = dataLora.text;
      updateMetrics(dataLora);
      addToHistory(dataLora.text, dataLora);
    } catch (err) {
      showToast(`Comparison Error: ${err.message}`, 4000);
    } finally {
      isGenerating = false;
      updateActionButtons();
    }
  }

  runOcrBtn.addEventListener("click", runSingleOcr);
  compareBtn.addEventListener("click", runComparison);

  // Copy & Download Actions
  copyBtn.addEventListener("click", async () => {
    if (!ocrOutput.value) return;
    await navigator.clipboard.writeText(ocrOutput.value);
    copyBtnText.textContent = "Copied!";
    showToast("Copied Khmer text to clipboard!");
    setTimeout(() => {
      copyBtnText.textContent = "Copy";
    }, 1800);
  });

  function downloadFile(content, filename, mimeType) {
    const blob = new Blob([content], { type: mimeType });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  }

  downloadTxtBtn.addEventListener("click", () => {
    downloadFile(ocrOutput.value, "khmer-ocr-output.txt", "text/plain;charset=utf-8");
  });

  if (downloadLayoutTxtBtn) {
    downloadLayoutTxtBtn.addEventListener("click", () => {
      downloadFile(ocrOutput.value, "khmer-ocr-layout.txt", "text/plain;charset=utf-8");
    });
  }

  if (copyLayoutBtn) {
    copyLayoutBtn.addEventListener("click", async () => {
      if (!ocrOutput.value) return;
      await navigator.clipboard.writeText(ocrOutput.value);
      copyLayoutBtnText.textContent = "បានចម្លង!";
      showToast("បានចម្លងអត្ថបទទៅកាន់ Clipboard!");
      setTimeout(() => {
        copyLayoutBtnText.textContent = "ចម្លង";
      }, 1800);
    });
  }

  async function exportDocx(mode = "layout") {
    try {
      const natW = imagePreview.naturalWidth || (lastResultMeta?.image_size?.width) || 1000;
      const natH = imagePreview.naturalHeight || (lastResultMeta?.image_size?.height) || 1000;
      const res = await fetch("/api/export/docx", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          text: ocrOutput.value,
          regions: detectedBoxes,
          image_size: { width: natW, height: natH },
          mode,
        }),
      });
      if (!res.ok) throw new Error("DOCX export failed");
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `khmer-ocr-${mode}.docx`;
      a.click();
      URL.revokeObjectURL(url);
      showToast("បានទាញយកឯកសារ Word (.DOCX) ដោយជោគជ័យ!");
    } catch (err) {
      showToast(`DOCX Error: ${err.message}`, 3500);
    }
  }

  if (downloadDocxPlainBtn) {
    downloadDocxPlainBtn.addEventListener("click", () => exportDocx("plain"));
  }
  if (downloadDocxLayoutBtn) {
    downloadDocxLayoutBtn.addEventListener("click", () => exportDocx("layout"));
  }

  downloadMdBtn.addEventListener("click", () => {
    const md = `# Khmer OCR Result\n\n${ocrOutput.value}\n`;
    downloadFile(md, "khmer-ocr-output.md", "text/markdown;charset=utf-8");
  });

  downloadJsonBtn.addEventListener("click", () => {
    const payload = {
      text: ocrOutput.value,
      regions: detectedBoxes,
      metadata: lastResultMeta,
      exported_at: new Date().toISOString(),
    };
    downloadFile(
      JSON.stringify(payload, null, 2),
      "khmer-ocr-output.json",
      "application/json;charset=utf-8"
    );
  });

  // Session History
  function addToHistory(text, meta) {
    if (!text) return;
    scanHistory.unshift({
      text,
      meta,
      thumb: currentDataUrl,
      timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
    });
    if (scanHistory.length > 10) scanHistory.pop();
    renderHistory();
  }

  function renderHistory() {
    historyCount.textContent = String(scanHistory.length);
    clearHistoryBtn.hidden = scanHistory.length === 0;

    if (scanHistory.length === 0) {
      historyList.innerHTML = `<p class="history-empty">Your OCR results in this session will be saved here for quick access.</p>`;
      return;
    }

    historyList.innerHTML = "";
    scanHistory.forEach((item) => {
      const card = document.createElement("div");
      card.className = "history-item";
      card.innerHTML = `
        <img class="history-thumb" src="${item.thumb || ""}" alt="thumb" />
        <div class="history-info">
          <div class="history-snippet">${escapeHtml(item.text)}</div>
          <div class="history-sub">${item.timestamp} • ${(item.meta.elapsed_ms / 1000).toFixed(1)}s</div>
        </div>
      `;
      card.addEventListener("click", () => {
        switchTab("combined");
        ocrOutput.value = item.text;
        updateMetrics(item.meta);
        updateActionButtons();
      });
      historyList.appendChild(card);
    });
  }

  clearHistoryBtn.addEventListener("click", () => {
    scanHistory = [];
    renderHistory();
  });

  function escapeHtml(str) {
    return str.replace(/[&<>"']/g, (c) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    }[c]));
  }

  checkStatus();
})();
