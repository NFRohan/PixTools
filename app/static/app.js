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

const btnProcess = document.getElementById('btn-process');
const processIndicator = document.getElementById('process-indicator');
const jobIdDisplay = document.getElementById('job-id-display');

const resultsSection = document.getElementById('results-section');
const resultCardsContainer = document.getElementById('result-cards-container');
const webhookWarning = document.getElementById('webhook-warning');
const btnProcessAnother = document.getElementById('btn-process-another');

const historySection = document.getElementById('history-section');
const historyContainer = document.getElementById('history-container');

// Templates
const tplResultCard = document.getElementById('tpl-result-card');
const tplHistoryItem = document.getElementById('tpl-history-item');

// --- State ---
let currentFile = null;
let currentExt = null;
let currentFormat = null;
let pollIntervalId = null;
let idempotencyKey = null;
let currentJobData = null; // Store latest successful job data for history

// File ext -> format mapping for same-format rejection
const EXT_TO_FORMAT = {
    'jpg': 'jpg', 'jpeg': 'jpg', 'png': 'png',
    'webp': 'webp', 'avif': 'avif'
};

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
}

checkboxes.forEach(cb => {
    cb.addEventListener('change', () => {
        hideError(opsError);
        checkProcessReady();
    });
});

function getSelectedOperations() {
    return Array.from(checkboxes).filter(cb => cb.checked).map(cb => cb.value);
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
    formData.append('idempotency_key', idempotencyKey);

    try {
        const response = await fetch('/api/process', {
            method: 'POST',
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
    if (pollIntervalId) clearInterval(pollIntervalId);

    pollIntervalId = setInterval(async () => {
        try {
            const response = await fetch(`/api/jobs/${jobId}`);
            const data = await response.json();

            if (!response.ok) throw new Error(data.detail || "Failed to fetch status");

            const status = data.status;

            if (status === 'COMPLETED' || status === 'COMPLETED_WEBHOOK_FAILED') {
                clearInterval(pollIntervalId);
                currentJobData = data;
                renderResults(data);
            } else if (status === 'FAILED') {
                clearInterval(pollIntervalId);
                showError(opsError, `Job Failed: ${data.error_message || 'Unknown error'}`);
                restoreProcessButton();
            }
            // else PENDING/PROCESSING -> keep polling

        } catch (err) {
            console.error("Polling error:", err);
            // Don't kill polling on a transient network error, just log it.
            // But if it's persistent, could add a retry counter here.
        }
    }, 2000);
}

// --- Results Rendering ---

function renderResults(jobData) {
    // Hide process indicator
    processIndicator.classList.add('hidden');

    // Clear old cards
    resultCardsContainer.innerHTML = '';

    // Show warning if webhook failed
    if (jobData.status === 'COMPLETED_WEBHOOK_FAILED') {
        webhookWarning.classList.remove('hidden');
    } else {
        webhookWarning.classList.add('hidden');
    }

    // Render cards
    const urls = jobData.result_urls || {};
    for (const [op, url] of Object.entries(urls)) {
        const clone = tplResultCard.content.cloneNode(true);
        const card = clone.querySelector('.result-card');

        clone.querySelector('.op-name').textContent = op.toUpperCase();

        // Thumbnail handling
        const img = clone.querySelector('.result-img');
        if (op === 'avif') {
            // AVIF support is spotty in browser <img> tags, provide fallback text
            // For now, we attempt to load it, but the alt text is the fallback
            img.src = url;
            img.onerror = () => {
                img.style.display = 'none';
                img.parentElement.innerHTML = '<div style="padding:1rem;font-weight:bold;text-align:center;">IMG 📥</div>';
            };
        } else {
            img.src = url;
        }

        // Specific styling class based on op
        card.classList.add(`op-${op}`);

        // Download button config
        const btn = clone.querySelector('.btn-download');
        btn.href = url;
        // The presigned URL handles the actual download, but we set a nice filename attribute
        const ext = op === 'denoise' ? currentExt : op;
        btn.download = `pixtools_${op}_${jobData.job_id.split('-')[0]}.${ext}`;

        resultCardsContainer.appendChild(clone);
    }

    // Show results section
    resultsSection.classList.remove('hidden');

    // Scroll to results
    resultsSection.scrollIntoView({ behavior: 'smooth' });
}

// --- Process Another / History ---

btnProcessAnother.addEventListener('click', () => {
    // Move current results to history
    if (currentJobData) {
        moveToHistory(currentJobData);
        currentJobData = null;
    }

    // Reset UI
    resultsSection.classList.add('hidden');
    restoreProcessButton();
    resetUploadState();

    // Unfreeze upload area
    dropZone.style.pointerEvents = 'auto';

    window.scrollTo({ top: 0, behavior: 'smooth' });
});

function moveToHistory(jobData) {
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

        const ext = op === 'denoise' ? currentExt : op;
        a.download = `pixtools_${op}_${shortId}.${ext}`;

        linksContainer.appendChild(a);
    }

    // Prepend to top
    historyContainer.prepend(clone);
}

// --- Helpers ---

function restoreProcessButton() {
    processIndicator.classList.add('hidden');
    btnProcess.classList.remove('hidden');
    updateOpsAvailability(); // re-checks disabled states based on current file
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
