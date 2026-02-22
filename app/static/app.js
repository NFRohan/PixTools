/**
 * PixTools Frontend Logic
 * Vanilla JS handling drag/drop, validation, API submission, and polling.
 */

const UPLOAD_LIMIT_BYTES = 10 * 1024 * 1024; // 10MB
const ACCEPTED_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/avif'];

// --- DOM Elements ---
const dropZone = document.getElementById('drop-zone');
const fileInput = document.getElementById('file-input');
const imagePreview = document.getElementById('image-preview');
const uploadPrompt = document.getElementById('upload-prompt');
const btnRemovePreview = document.getElementById('btn-remove-preview');
const uploadError = document.getElementById('upload-error');

const checkboxes = document.querySelectorAll('input[name="operation"]');
const opsError = document.getElementById('ops-error');
const advancedControls = document.getElementById('advanced-controls');
const qualityControl = document.getElementById('quality-control');
const resizeControl = document.getElementById('resize-control');
const qualityRange = document.getElementById('quality-range');
const qualityValue = document.getElementById('quality-value');
const resizeWidthInput = document.getElementById('resize-width');
const resizeHeightInput = document.getElementById('resize-height');
const webhookUrlInput = document.getElementById('webhook-url');

const btnProcess = document.getElementById('btn-process');
const processIndicator = document.getElementById('process-indicator');
const jobIdDisplay = document.getElementById('job-id-display');

const resultsSection = document.getElementById('results-section');
const resultCardsContainer = document.getElementById('result-cards-container');
const webhookWarning = document.getElementById('webhook-warning');
const btnDownloadAll = document.getElementById('btn-download-all');
const btnProcessAnother = document.getElementById('btn-process-another');
const metadataPanel = document.getElementById('metadata-panel');
const metadataContent = document.getElementById('metadata-content');

const historySection = document.getElementById('history-section');
const historyContainer = document.getElementById('history-container');
const btnClearHistory = document.getElementById('btn-clear-history');

// Templates
const tplResultCard = document.getElementById('tpl-result-card');
const tplHistoryItem = document.getElementById('tpl-history-item');

// --- State ---
const STORAGE_KEY = 'pixtools_jobs';
const HISTORY_LIMIT = 10;
const RETENTION_HOURS = 24;

let currentFile = null;
let currentExt = null;
let currentFormat = null;
let pollIntervalId = null;
let pollToken = 0;
let idempotencyKey = null;
let currentJobData = null; // Store latest successful job data for history

// File ext -> format mapping for same-format rejection
const EXT_TO_FORMAT = {
    'jpg': 'jpg', 'jpeg': 'jpg', 'png': 'png',
    'webp': 'webp', 'avif': 'avif'
};
const QUALITY_OPS = new Set(['jpg', 'webp']);
const RESIZE_OPS = new Set(['jpg', 'png', 'webp', 'avif', 'denoise']);

// --- Initialization ---

function init() {
    loadHistoryFromStorage();
    updateAdvancedControls();
    btnClearHistory?.addEventListener('click', clearHistory);
}

document.addEventListener('DOMContentLoaded', init);

qualityRange?.addEventListener('input', () => {
    qualityValue.textContent = qualityRange.value;
});

// --- Drag & Drop / File Selection ---

// Click zone to open file dialog
dropZone.addEventListener('click', (e) => {
    if (e.target !== btnRemovePreview) fileInput.click();
});

// Drag events
dropZone.addEventListener('dragover', (e) => {
    e.preventDefault();
    dropZone.classList.add('dragover');
});
dropZone.addEventListener('dragleave', () => dropZone.classList.remove('dragover'));
dropZone.addEventListener('drop', (e) => {
    e.preventDefault();
    dropZone.classList.remove('dragover');
    if (e.dataTransfer.files.length) handleFile(e.dataTransfer.files[0]);
});

fileInput.addEventListener('change', (e) => {
    if (e.target.files.length) handleFile(e.target.files[0]);
});

function handleFile(file) {
    hideError(uploadError);
    hideError(opsError);

    if (!ACCEPTED_TYPES.includes(file.type)) {
        showError(uploadError, `Invalid type: ${file.type}. Allowed: JPG, PNG, WEBP, AVIF.`);
        return;
    }
    if (file.size > UPLOAD_LIMIT_BYTES) {
        showError(uploadError, `File too large (${(file.size / 1024 / 1024).toFixed(1)}MB). Max 10MB.`);
        return;
    }

    currentFile = file;
    currentExt = file.name.split('.').pop().toLowerCase();
    currentFormat = EXT_TO_FORMAT[currentExt] || null;

    // Show preview
    const reader = new FileReader();
    reader.onload = (e) => {
        imagePreview.src = e.target.result;
        imagePreview.classList.remove('hidden');
        uploadPrompt.classList.add('hidden');
        btnRemovePreview.classList.remove('hidden');
    };
    reader.readAsDataURL(file);

    updateOpsAvailability();
    checkProcessReady();
}

btnRemovePreview.addEventListener('click', (e) => {
    e.stopPropagation(); // prevent clicking dropzone
    resetUploadState();
});

function resetUploadState() {
    currentFile = null;
    currentExt = null;
    currentFormat = null;
    fileInput.value = '';
    imagePreview.src = '';
    imagePreview.classList.add('hidden');
    uploadPrompt.classList.remove('hidden');
    btnRemovePreview.classList.add('hidden');
    hideError(uploadError);
    hideError(opsError);
    // Uncheck and enable all
    checkboxes.forEach(cb => {
        cb.checked = false;
        cb.closest('.op-checkbox').classList.remove('disabled');
        cb.disabled = false;
    });
    qualityRange.value = '80';
    qualityValue.textContent = '80';
    resizeWidthInput.value = '';
    resizeHeightInput.value = '';
    webhookUrlInput.value = '';
    updateAdvancedControls();
    checkProcessReady();
}

// --- Operations Selection ---

function updateOpsAvailability() {
    // Disable same-format conversion
    checkboxes.forEach(cb => {
        const opVal = cb.value;
        const wrapper = cb.closest('.op-checkbox');

        if (opVal !== 'denoise' && opVal === currentFormat) {
            cb.checked = false;
            cb.disabled = true;
            wrapper.classList.add('disabled');
        } else {
            cb.disabled = false;
            wrapper.classList.remove('disabled');
        }
    });
    updateAdvancedControls();
}

function updateAdvancedControls() {
    const selectedOps = getSelectedOperations();
    const hasOps = selectedOps.length > 0;
    const supportsQuality = selectedOps.some(op => QUALITY_OPS.has(op));
    const supportsResize = selectedOps.some(op => RESIZE_OPS.has(op));

    if (hasOps) {
        advancedControls.classList.remove('hidden');
    } else {
        advancedControls.classList.add('hidden');
    }

    if (supportsQuality) {
        qualityControl.classList.remove('hidden');
    } else {
        qualityControl.classList.add('hidden');
    }

    if (supportsResize) {
        resizeControl.classList.remove('hidden');
    } else {
        resizeControl.classList.add('hidden');
    }
}

checkboxes.forEach(cb => {
    cb.addEventListener('change', () => {
        hideError(opsError);
        updateAdvancedControls();
        checkProcessReady();
    });
});

function getSelectedOperations() {
    return Array.from(checkboxes).filter(cb => cb.checked).map(cb => cb.value);
}

function getOperationParams(selectedOps) {
    const params = {};
    const widthRaw = resizeWidthInput.value.trim();
    const heightRaw = resizeHeightInput.value.trim();
    const hasResize = widthRaw !== '' || heightRaw !== '';

    selectedOps.forEach(op => {
        const opParams = {};

        if (QUALITY_OPS.has(op) && !qualityControl.classList.contains('hidden')) {
            opParams.quality = Number(qualityRange.value);
        }

        if (hasResize && RESIZE_OPS.has(op)) {
            const resize = {};
            if (widthRaw !== '') resize.width = Number(widthRaw);
            if (heightRaw !== '') resize.height = Number(heightRaw);
            opParams.resize = resize;
        }

        if (Object.keys(opParams).length > 0) {
            params[op] = opParams;
        }
    });

    return params;
}

function checkProcessReady() {
    const hasFile = currentFile !== null;
    const hasOps = getSelectedOperations().length > 0;
    btnProcess.disabled = !(hasFile && hasOps);
}

// --- API Interaction ---

btnProcess.addEventListener('click', async () => {
    const ops = getSelectedOperations();
    if (!currentFile || ops.length === 0) return;
    const opParams = getOperationParams(ops);
    const webhookUrl = webhookUrlInput.value.trim();

    // Start processing state
    btnProcess.classList.add('hidden');
    processIndicator.classList.remove('hidden');
    jobIdDisplay.textContent = "Uploading...";

    // Disable inputs
    dropZone.style.pointerEvents = 'none';
    checkboxes.forEach(cb => cb.disabled = true);

    // Generate idempotency key for this exact file + ops combo
    idempotencyKey = crypto.randomUUID();

    const formData = new FormData();
    formData.append('file', currentFile);
    formData.append('operations', JSON.stringify(ops));
    if (Object.keys(opParams).length > 0) {
        formData.append('operation_params', JSON.stringify(opParams));
    }
    if (webhookUrl) {
        formData.append('webhook_url', webhookUrl);
    }

    try {
        const response = await fetch('/api/process', {
            method: 'POST',
            headers: {
                'Idempotency-Key': idempotencyKey
            },
            body: formData // No Content-Type header needed for FormData
        });

        const data = await response.json();

        if (!response.ok) {
            throw new Error(data.detail || `Server error: ${response.status}`);
        }

        const jobId = data.job_id;
        jobIdDisplay.textContent = `Job: ${jobId.split('-')[0]}...`;

        // Start polling
        startPolling(jobId);

    } catch (err) {
        showError(opsError, err.message);
        restoreProcessButton();
    }
});

// --- Polling ---

function startPolling(jobId) {
    if (pollIntervalId) {
        clearInterval(pollIntervalId);
        pollIntervalId = null;
    }
    const currentPollToken = ++pollToken;
    let archivePollAttempts = 0;
    const maxArchivePollAttempts = 30;

    pollIntervalId = setInterval(async () => {
        try {
            if (currentPollToken !== pollToken) {
                return;
            }

            const response = await fetch(`/api/jobs/${jobId}`);
            if (currentPollToken !== pollToken) {
                return;
            }
            const data = await response.json();

            if (!response.ok) throw new Error(data.detail || "Failed to fetch status");

            const status = data.status;

            if (status === 'COMPLETED' || status === 'COMPLETED_WEBHOOK_FAILED') {
                const previousJobData = currentJobData;
                const previousMetadata = previousJobData?.metadata || {};
                const currentMetadata = data.metadata || {};
                const shouldRender =
                    !previousJobData ||
                    previousJobData.job_id !== data.job_id ||
                    Boolean(previousJobData.archive_url) !== Boolean(data.archive_url) ||
                    JSON.stringify(previousMetadata) !== JSON.stringify(currentMetadata);

                currentJobData = data;

                if (shouldRender) {
                    const shouldScroll = resultsSection.classList.contains('hidden');
                    renderResults(data, { shouldScroll });
                }

                const hasResultFiles = Object.keys(data.result_urls || {}).length > 0;
                const waitingForArchive = hasResultFiles && !data.archive_url;
                if (!waitingForArchive || archivePollAttempts >= maxArchivePollAttempts) {
                    clearInterval(pollIntervalId);
                    pollIntervalId = null;
                } else {
                    archivePollAttempts += 1;
                }
            } else if (status === 'FAILED') {
                clearInterval(pollIntervalId);
                pollIntervalId = null;
                showError(opsError, `Job Failed: ${data.error_message || 'Unknown error'}`);
                restoreProcessButton();
            }
            // else PENDING/PROCESSING -> keep polling

        } catch (err) {
            console.error("Polling error:", err);
        }
    }, 2000);
}

// --- Results Rendering ---

function renderResults(jobData, options = {}) {
    const shouldScroll = options.shouldScroll !== false;
    processIndicator.classList.add('hidden');
    resultCardsContainer.innerHTML = '';
    metadataContent.innerHTML = '';

    if (jobData.status === 'COMPLETED_WEBHOOK_FAILED') {
        webhookWarning.classList.remove('hidden');
    } else {
        webhookWarning.classList.add('hidden');
    }

    if (jobData.archive_url) {
        btnDownloadAll.href = jobData.archive_url;
        btnDownloadAll.download = `pixtools_bundle_${jobData.job_id.split('-')[0]}.zip`;
        btnDownloadAll.classList.remove('hidden');
    } else {
        btnDownloadAll.classList.add('hidden');
    }

    const urls = jobData.result_urls || {};
    for (const [op, url] of Object.entries(urls)) {
        const clone = tplResultCard.content.cloneNode(true);
        const card = clone.querySelector('.result-card');

        clone.querySelector('.op-name').textContent = op.toUpperCase();

        const img = clone.querySelector('.result-img');
        img.src = url;
        img.onerror = () => {
            img.style.display = 'none';
            img.parentElement.innerHTML = '<div style="padding:1rem;font-weight:bold;text-align:center;">IMG 📥</div>';
        };

        card.classList.add(`op-${op}`);

        const btn = clone.querySelector('.btn-download');
        btn.href = url;
        const ext = op === 'denoise' ? 'result' : op;
        btn.download = `pixtools_${op}_${jobData.job_id.split('-')[0]}.${ext}`;

        resultCardsContainer.appendChild(clone);
    }

    renderMetadata(jobData.metadata || {});
    if (isJobDownloadable(jobData)) {
        saveJobToStorage(jobData.job_id);
    }

    resultsSection.classList.remove('hidden');
    if (shouldScroll) {
        resultsSection.scrollIntoView({ behavior: 'smooth' });
    }
}

function renderMetadata(metadata) {
    const entries = Object.entries(metadata || {});
    if (entries.length === 0) {
        metadataPanel.classList.add('hidden');
        return;
    }

    metadataPanel.classList.remove('hidden');

    entries.forEach(([key, value]) => {
        const item = document.createElement('div');
        item.className = 'metadata-item';

        const k = document.createElement('div');
        k.className = 'metadata-key';
        k.textContent = key.replaceAll('_', ' ').toUpperCase();

        const v = document.createElement('div');
        v.className = 'metadata-value';
        v.textContent = typeof value === 'object' ? JSON.stringify(value) : String(value);

        item.appendChild(k);
        item.appendChild(v);
        metadataContent.appendChild(item);
    });
}

// --- Process Another / History ---

btnProcessAnother.addEventListener('click', () => {
    pollToken += 1;
    if (pollIntervalId) {
        clearInterval(pollIntervalId);
        pollIntervalId = null;
    }

    if (currentJobData) {
        moveToHistory(currentJobData);
        currentJobData = null;
    }

    resultsSection.classList.add('hidden');
    btnDownloadAll.classList.add('hidden');
    metadataPanel.classList.add('hidden');
    restoreProcessButton();
    resetUploadState();
    dropZone.style.pointerEvents = 'auto';
    window.scrollTo({ top: 0, behavior: 'smooth' });
});

function moveToHistory(jobData) {
    if (!isJobDownloadable(jobData)) {
        return;
    }

    historySection.classList.remove('hidden');

    const clone = tplHistoryItem.content.cloneNode(true);
    const shortId = jobData.job_id.split('-')[0];

    clone.querySelector('.history-id').textContent = `JOB ${shortId}`;
    clone.querySelector('.history-ops').textContent = jobData.operations.join(' • ').toUpperCase();

    const linksContainer = clone.querySelector('.history-links');

    const urls = jobData.result_urls || {};
    for (const [op, url] of Object.entries(urls)) {
        const a = document.createElement('a');
        a.href = url;
        a.className = 'history-link';
        a.textContent = op.toUpperCase();
        const ext = op === 'denoise' ? 'result' : op;
        a.download = `pixtools_${op}_${shortId}.${ext}`;
        linksContainer.appendChild(a);
    }
    if (jobData.archive_url) {
        const zipLink = document.createElement('a');
        zipLink.href = jobData.archive_url;
        zipLink.className = 'history-link';
        zipLink.textContent = 'ZIP';
        zipLink.download = `pixtools_bundle_${shortId}.zip`;
        linksContainer.appendChild(zipLink);
    }

    historyContainer.prepend(clone);
}

// --- Persistence Helpers ---

function saveJobToStorage(jobId) {
    let jobs = JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]');
    // Avoid duplicates
    if (!jobs.includes(jobId)) {
        jobs.push(jobId);
        // Limit history size
        if (jobs.length > HISTORY_LIMIT) jobs.shift();
        localStorage.setItem(STORAGE_KEY, JSON.stringify(jobs));
    }
}

async function loadHistoryFromStorage() {
    const jobs = JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]');
    if (jobs.length === 0) return;

    // Fetch details for each job
    // We do this sequentially to avoid overwhelming the server, or use Promise.all
    const jobDataPromises = jobs.map(id => fetch(`/api/jobs/${id}`).then(r => r.ok ? r.json() : null));
    const allJobs = await Promise.all(jobDataPromises);
    const validIds = [];

    allJobs.forEach((data, index) => {
        if (!isJobDownloadable(data)) return;
        moveToHistory(data);
        validIds.push(jobs[index]);
    });

    const compacted = validIds.slice(-HISTORY_LIMIT);
    localStorage.setItem(STORAGE_KEY, JSON.stringify(compacted));
    if (compacted.length === 0) {
        historySection.classList.add('hidden');
    }
}

function checkExpiry(isoString) {
    if (!isoString) return true;
    const created = new Date(isoString);
    const now = new Date();
    const diffHours = (now - created) / (1000 * 60 * 60);
    return diffHours >= RETENTION_HOURS;
}

function isJobDownloadable(jobData) {
    if (!jobData) return false;
    const done = jobData.status === 'COMPLETED' || jobData.status === 'COMPLETED_WEBHOOK_FAILED';
    if (!done) return false;
    if (checkExpiry(jobData.created_at)) return false;

    const hasResultUrls = jobData.result_urls && Object.keys(jobData.result_urls).length > 0;
    const hasArchive = Boolean(jobData.archive_url);
    return hasResultUrls || hasArchive;
}

// --- Helpers ---

function restoreProcessButton() {
    processIndicator.classList.add('hidden');
    btnProcess.classList.remove('hidden');
    updateOpsAvailability();
    if (currentFile) {
        checkboxes.forEach(cb => {
            if (!cb.closest('.op-checkbox').classList.contains('disabled')) {
                cb.disabled = false;
            }
        });
    }
    checkProcessReady();
}

function showError(container, message) {
    container.textContent = message;
    container.classList.remove('hidden');
}

function hideError(container) {
    container.classList.add('hidden');
    container.textContent = '';
}
function clearHistory() {
    localStorage.removeItem(STORAGE_KEY);
    historyContainer.innerHTML = '';
    historySection.classList.add('hidden');
}
